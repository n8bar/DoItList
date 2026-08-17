defmodule DoitMcp.HttpTokenRecoveryTest do
  # async: false — boots the anubis HTTP tree under its real global registry
  # names and swaps the global :req_options app env.
  use ExUnit.Case, async: false

  import Plug.Test, only: [conn: 3]

  alias Anubis.Server.Transport.StreamableHTTP

  @moduletag :capture_log

  # 401 recovery on the resident HTTP transport (m03.04 2.2.1.3 + 2.3.3),
  # end-to-end through DoitMcp.Http.Plug against the real tree: a rejected
  # bearer sends the paste-a-fresh-token form on that session's OWN stream
  # and the call RETURNS AT ONCE with the actionable error — the human-paced
  # answer lands out-of-band, and the next call proves the paste. The
  # accepted token overrides that session's header token for the rest of the
  # session and is NEVER persisted or visible to another session — a
  # concurrent session with a valid token proceeds untouched throughout, and
  # one sharing the dead token gets guidance, not the override. Declined,
  # rejected, and unusable pastes latch; an unanswered form does not; a
  # streamless session gets the durable fix instead: the client's token
  # source.

  setup do
    # Recovery holds a fresh token in memory only — point a persist path
    # somewhere observable and assert nothing is ever written there.
    tmp = Path.join(System.tmp_dir!(), "http-recovery-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    persist_path = Path.join(tmp, "refresh.env")
    Application.put_env(:doit_mcp, :token_persist_path, persist_path)

    previous_req = Application.fetch_env(:doit_mcp, :req_options)

    on_exit(fn ->
      Application.delete_env(:doit_mcp, :token_persist_path)
      File.rm_rf!(tmp)

      case previous_req do
        {:ok, value} -> Application.put_env(:doit_mcp, :req_options, value)
        :error -> Application.delete_env(:doit_mcp, :req_options)
      end
    end)

    start_supervised!({DoitMcp.Server, transport: {:streamable_http, start: true}})
    %{persist_path: persist_path}
  end

  # Stub answering 401 unless the bearer matches `good`, reporting each
  # attempt's Authorization header to the test.
  defp stub_401_unless(good, test_pid) do
    Application.put_env(:doit_mcp, :req_options,
      plug: fn conn ->
        [header] = Plug.Conn.get_req_header(conn, "authorization")
        send(test_pid, {:api_call, header})

        if header == "Bearer #{good}" do
          Req.Test.json(conn, %{"data" => %{"id" => 7, "email" => "op@example.com"}})
        else
          conn
          |> Plug.Conn.put_status(401)
          |> Req.Test.json(%{
            "error" => %{"code" => "unauthorized", "message" => "invalid token"}
          })
        end
      end
    )
  end

  defp plug_opts, do: DoitMcp.Http.Plug.init(server: DoitMcp.Server)

  defp post_frame(message, headers) do
    conn =
      conn(:post, "/", Jason.encode!(message))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", "application/json")

    headers
    |> Enum.reduce(conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
    |> DoitMcp.Http.Plug.call(plug_opts())
  end

  defp handshake(headers) do
    initialize = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-06-18",
        "clientInfo" => %{"name" => "http-recovery-test", "version" => "1.0"},
        "capabilities" => %{"elicitation" => %{}}
      }
    }

    conn = post_frame(initialize, headers)
    assert conn.status == 200
    [session_id] = Plug.Conn.get_resp_header(conn, "mcp-session-id")

    conn =
      post_frame(
        %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
        [{"mcp-session-id", session_id} | headers]
      )

    assert conn.status == 202
    session_id
  end

  # Stand-in for the session's standalone GET stream — see
  # DoitMcp.HttpImportGateE2eTest for the rationale.
  defp open_stream(session_id) do
    test = self()
    transport = Anubis.Server.Registry.transport_name(DoitMcp.Server, :streamable_http)

    spawn_link(fn ->
      :ok = StreamableHTTP.register_sse_handler(transport, session_id)
      send(test, {:stream_open, session_id})
      stream_loop(test, session_id)
    end)

    assert_receive {:stream_open, ^session_id}, 2_000
    :ok
  end

  defp stream_loop(test, session_id) do
    receive do
      {:sse_message, wire} ->
        send(test, {:sse, session_id, Jason.decode!(wire)})
        stream_loop(test, session_id)

      _other ->
        stream_loop(test, session_id)
    end
  end

  defp get_me_call(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => "get_me", "arguments" => %{}}
    }
  end

  defp answer(elicitation_id, result, headers) do
    post_frame(%{"jsonrpc" => "2.0", "id" => elicitation_id, "result" => result}, headers)
  end

  defp tool_result(conn) do
    assert conn.status == 200
    assert %{"result" => result} = Jason.decode!(conn.resp_body)
    assert [%{"type" => "text", "text" => text} | _] = result["content"]
    {result["isError"], text}
  end

  # The out-of-band waiter parked on this session's form (m03.04 2.3.3):
  # monitor it, so a test can wait for its exit — the point at which the
  # answer has landed in the session's recovery state — instead of racing
  # the next call against it.
  defp monitor_waiter(session_id) do
    registry = Anubis.Server.Registry.registry_name(DoitMcp.Server)
    {:ok, session} = Anubis.Server.Registry.Local.lookup_session(registry, session_id)
    [{waiter, :async}] = Registry.lookup(DoitMcp.Elicitation.Registry, session)
    Process.monitor(waiter)
  end

  # The one form on this session's stream, consumed; anything else on the
  # stream (the session's own cancel notices) is ignored.
  defp receive_form(session_id) do
    assert_receive {:sse, ^session_id,
                    %{"method" => "elicitation/create", "id" => id, "params" => params}},
                   5_000

    {id, params}
  end

  defp assert_form_words(message) do
    assert message =~ "No minted DoItList API token matches"
    assert message =~ "Paste a fresh token"
    assert message =~ "this session only"
    assert message =~ "DOITLIST_API_TOKEN"
    assert message =~ "Authorization header"
    refute message =~ "revoked"
    refute message =~ "mcp.env"
  end

  test "a dead bearer's 401 returns at once with the form on its own stream; the paste lands out-of-band, for that session only",
       %{persist_path: persist_path} do
    stub_401_unless("fresh-token", self())

    dead = [{"authorization", "Bearer dead-token"}]
    valid = [{"authorization", "Bearer fresh-token"}]
    session_a = handshake(dead)
    session_b = handshake(valid)
    session_c = handshake(dead)
    open_stream(session_a)
    open_stream(session_b)

    a_headers = [{"mcp-session-id", session_a} | dead]
    b_headers = [{"mcp-session-id", session_b} | valid]

    # The 401 call returns inside the dispatch bound — no answer has been
    # given, and the result already carries the actionable words: the form
    # is open, the token source to check, re-call.
    assert {true, text} = tool_result(post_frame(get_me_call(2), a_headers))
    assert text =~ "No minted DoItList API token matches"
    assert text =~ "form is open"
    assert text =~ "DOITLIST_API_TOKEN"
    assert text =~ "re-call"
    refute text =~ "revoked"
    assert_received {:api_call, "Bearer dead-token"}

    # The form rode session A's stream, naming the durable fix.
    {elicitation_id, %{"message" => message, "requestedSchema" => schema}} =
      receive_form(session_a)

    assert_form_words(message)
    assert schema["required"] == ["token"]

    # A second 401 on A while the form is pending says so — no second form.
    assert {true, text} = tool_result(post_frame(get_me_call(3), a_headers))
    assert text =~ "still open"
    assert text =~ "re-call"
    assert_received {:api_call, "Bearer dead-token"}
    refute_received {:sse, ^session_a, %{"method" => "elicitation/create"}}

    # The concurrent valid-token session proceeds untouched mid-recovery.
    assert {false, _text} = tool_result(post_frame(get_me_call(4), b_headers))
    assert_received {:api_call, "Bearer fresh-token"}
    refute_received {:sse, ^session_b, _frame}

    waiter = monitor_waiter(session_a)

    conn =
      answer(
        elicitation_id,
        %{"action" => "accept", "content" => %{"token" => "fresh-token"}},
        a_headers
      )

    assert conn.status == 202
    assert_receive {:DOWN, ^waiter, :process, _pid, :normal}, 5_000

    # The next call on A proves the paste — one attempt, with the pasted
    # token — and flows; the header still carries the dead token.
    assert {false, _text} = tool_result(post_frame(get_me_call(5), a_headers))
    assert_received {:api_call, "Bearer fresh-token"}
    refute_received {:api_call, _header}
    refute_received {:sse, ^session_a, %{"method" => "elicitation/create"}}

    # And every call after rides the proven override.
    assert {false, _text} = tool_result(post_frame(get_me_call(6), a_headers))
    assert_received {:api_call, "Bearer fresh-token"}
    refute_received {:sse, ^session_a, %{"method" => "elicitation/create"}}

    # Session C shares the dead header but never sees A's override: no
    # stream, so its 401 goes straight to guidance — no elicitation, no
    # attempt with a token it was never granted.
    assert {true, text} =
             tool_result(post_frame(get_me_call(7), [{"mcp-session-id", session_c} | dead]))

    assert text =~ "no open server-to-client stream"
    assert_received {:api_call, "Bearer dead-token"}
    refute_received {:api_call, _header}

    # No token reached disk.
    refute File.exists?(persist_path)
    refute_received {:sse, ^session_b, _frame}
  end

  test "a declined form latches that session with the token-source guidance", %{
    persist_path: persist_path
  } do
    stub_401_unless("never-granted", self())

    dead = [{"authorization", "Bearer dead-token"}]
    session = handshake(dead)
    open_stream(session)
    headers = [{"mcp-session-id", session} | dead]

    assert {true, text} = tool_result(post_frame(get_me_call(2), headers))
    assert text =~ "form is open"
    {elicitation_id, _params} = receive_form(session)

    waiter = monitor_waiter(session)
    conn = answer(elicitation_id, %{"action" => "decline"}, headers)
    assert conn.status == 202
    assert_receive {:DOWN, ^waiter, :process, _pid, :normal}, 5_000

    # The latch holds: the next 401 goes straight to the error, no new form.
    assert {true, text} = tool_result(post_frame(get_me_call(3), headers))
    assert text =~ "declined"
    assert text =~ "not asking again"
    assert text =~ "DOITLIST_API_TOKEN"
    assert text =~ "Authorization header"
    refute text =~ "revoked"
    refute text =~ "mcp.env"
    refute_received {:sse, ^session, %{"method" => "elicitation/create"}}
    refute File.exists?(persist_path)
  end

  test "a paste the API rejects, or one that is no token, latches — never a second form" do
    stub_401_unless("never-granted", self())

    dead = [{"authorization", "Bearer dead-token"}]

    # A rejected paste: the next call proves it — one attempt, a 401 — and
    # latches; the call after rides the header token straight to the latch.
    session_r = handshake(dead)
    open_stream(session_r)
    r_headers = [{"mcp-session-id", session_r} | dead]

    assert {true, _text} = tool_result(post_frame(get_me_call(2), r_headers))
    {elicitation_id, _params} = receive_form(session_r)
    assert_received {:api_call, "Bearer dead-token"}

    waiter = monitor_waiter(session_r)

    conn =
      answer(
        elicitation_id,
        %{"action" => "accept", "content" => %{"token" => "still-dead"}},
        r_headers
      )

    assert conn.status == 202
    assert_receive {:DOWN, ^waiter, :process, _pid, :normal}, 5_000

    assert {true, text} = tool_result(post_frame(get_me_call(3), r_headers))
    assert text =~ "rejected too"
    assert text =~ "not asking again"
    assert_received {:api_call, "Bearer still-dead"}
    refute_received {:api_call, _header}
    refute_received {:sse, ^session_r, %{"method" => "elicitation/create"}}

    assert {true, text} = tool_result(post_frame(get_me_call(4), r_headers))
    assert text =~ "already declined or rejected"
    assert_received {:api_call, "Bearer dead-token"}
    refute_received {:api_call, _header}
    refute_received {:sse, ^session_r, %{"method" => "elicitation/create"}}

    # An unusable paste latches without any attempt.
    session_u = handshake(dead)
    open_stream(session_u)
    u_headers = [{"mcp-session-id", session_u} | dead]

    assert {true, _text} = tool_result(post_frame(get_me_call(2), u_headers))
    {elicitation_id, _params} = receive_form(session_u)
    assert_received {:api_call, "Bearer dead-token"}

    waiter = monitor_waiter(session_u)

    conn =
      answer(
        elicitation_id,
        %{"action" => "accept", "content" => %{"token" => "not a token!"}},
        u_headers
      )

    assert conn.status == 202
    assert_receive {:DOWN, ^waiter, :process, _pid, :normal}, 5_000

    assert {true, text} = tool_result(post_frame(get_me_call(3), u_headers))
    assert text =~ "not asking again"
    assert_received {:api_call, "Bearer dead-token"}
    refute_received {:api_call, _header}
    refute_received {:sse, ^session_u, %{"method" => "elicitation/create"}}
  end

  test "an unanswered form expires without latching — the next 401 asks again" do
    stub_401_unless("never-granted", self())

    dead = [{"authorization", "Bearer dead-token"}]
    session = handshake(dead)
    open_stream(session)
    headers = [{"mcp-session-id", session} | dead]

    Application.put_env(:doit_mcp, :token_recovery_timeout, 100)
    on_exit(fn -> Application.delete_env(:doit_mcp, :token_recovery_timeout) end)

    assert {true, text} = tool_result(post_frame(get_me_call(2), headers))
    assert text =~ "form is open"
    {_elicitation_id, _params} = receive_form(session)

    # The waiter lapses on its own clock (the window plus a second of skew)
    # — nobody answered, nothing latched.
    waiter = monitor_waiter(session)
    assert_receive {:DOWN, ^waiter, :process, _pid, :normal}, 5_000

    assert {true, text} = tool_result(post_frame(get_me_call(3), headers))
    assert text =~ "form is open"
    refute text =~ "not asking again"
    {_elicitation_id, %{"message" => message}} = receive_form(session)
    assert_form_words(message)
  end

  test "no open stream skips the form — straight to the token-source guidance" do
    stub_401_unless("never-granted", self())

    dead = [{"authorization", "Bearer dead-token"}]
    session = handshake(dead)
    headers = [{"mcp-session-id", session} | dead]

    # A regression past the stream check would park on the paste window —
    # keep it tiny so the failure is milliseconds; the correct path never
    # touches it.
    Application.put_env(:doit_mcp, :token_recovery_timeout, 100)
    on_exit(fn -> Application.delete_env(:doit_mcp, :token_recovery_timeout) end)

    call = Task.async(fn -> post_frame(get_me_call(2), headers) end)

    assert {true, text} = tool_result(Task.await(call, 5_000))
    assert text =~ "no open server-to-client stream"
    assert text =~ "DOITLIST_API_TOKEN"
    assert text =~ "Authorization header"
    refute text =~ "revoked"
    refute text =~ "mcp.env"

    # Exactly the one 401 attempt — nothing retried.
    assert_received {:api_call, "Bearer dead-token"}
    refute_received {:api_call, _header}
  end
end
