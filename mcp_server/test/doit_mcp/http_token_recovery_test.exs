defmodule DoitMcp.HttpTokenRecoveryTest do
  # async: false — boots the anubis HTTP tree under its real global registry
  # names and swaps the global :req_options app env.
  use ExUnit.Case, async: false

  import Plug.Test, only: [conn: 3]

  alias Anubis.Server.Transport.StreamableHTTP

  @moduletag :capture_log

  # 401 recovery on the resident HTTP transport (m03.04 2.5.3),
  # end-to-end through DoitMcp.Http.Plug against the real tree: a rejected
  # bearer raises the paste-a-fresh-token form on that session's OWN stream;
  # the accepted token overrides that session's header token for the rest of
  # the session and is NEVER persisted or visible to another session — a
  # concurrent session with a valid token proceeds untouched throughout, and
  # one sharing the dead token gets guidance, not the override. Declined and
  # streamless sessions get the durable fix instead: the Authorization
  # header in the client config.

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

  test "a dead bearer elicits on its own stream; the accepted token is held for that session only",
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

    call = Task.async(fn -> post_frame(get_me_call(2), a_headers) end)

    # The form rides session A's stream, naming the durable fix: the
    # Authorization header in the client config.
    assert_receive {:sse, ^session_a,
                    %{
                      "method" => "elicitation/create",
                      "id" => elicitation_id,
                      "params" => %{"message" => message, "requestedSchema" => schema}
                    }},
                   5_000

    assert message =~ "Paste a fresh API token"
    assert message =~ "holds for this session only"
    assert message =~ "Authorization header"
    refute message =~ "mcp.env"
    assert schema["required"] == ["token"]
    assert_received {:api_call, "Bearer dead-token"}

    # The concurrent valid-token session proceeds untouched mid-recovery.
    assert {false, _text} = tool_result(post_frame(get_me_call(3), b_headers))
    assert_received {:api_call, "Bearer fresh-token"}
    refute_received {:sse, ^session_b, _frame}

    conn =
      answer(
        elicitation_id,
        %{"action" => "accept", "content" => %{"token" => "fresh-token"}},
        a_headers
      )

    assert conn.status == 202

    # The held call resolved by the one verify retry with the pasted token.
    assert {false, _text} = tool_result(Task.await(call, 10_000))
    assert_received {:api_call, "Bearer fresh-token"}

    # Later calls on session A ride the override — the header still carries
    # the dead token.
    assert {false, _text} = tool_result(post_frame(get_me_call(4), a_headers))
    assert_received {:api_call, "Bearer fresh-token"}
    refute_received {:sse, ^session_a, _frame}

    # Session C shares the dead header but never sees A's override: no
    # stream, so its 401 goes straight to guidance — no elicitation, no
    # retry with a token it was never granted.
    assert {true, text} =
             tool_result(post_frame(get_me_call(5), [{"mcp-session-id", session_c} | dead]))

    assert text =~ "no open server-to-client stream"
    assert_received {:api_call, "Bearer dead-token"}
    refute_received {:api_call, _header}

    # No token reached disk.
    refute File.exists?(persist_path)
    refute_received {:sse, ^session_b, _frame}
  end

  test "a declined form latches that session with the header guidance", %{
    persist_path: persist_path
  } do
    stub_401_unless("never-granted", self())

    dead = [{"authorization", "Bearer dead-token"}]
    session = handshake(dead)
    open_stream(session)
    headers = [{"mcp-session-id", session} | dead]

    call = Task.async(fn -> post_frame(get_me_call(2), headers) end)

    assert_receive {:sse, ^session, %{"method" => "elicitation/create", "id" => elicitation_id}},
                   5_000

    conn = answer(elicitation_id, %{"action" => "decline"}, headers)
    assert conn.status == 202

    assert {true, text} = tool_result(Task.await(call, 10_000))
    assert text =~ "declined"
    assert text =~ "Authorization header"
    refute text =~ "mcp.env"

    # The latch holds: the next 401 goes straight to the error, no new form.
    assert {true, text} = tool_result(post_frame(get_me_call(3), headers))
    assert text =~ "not asking again"
    refute_received {:sse, ^session, %{"method" => "elicitation/create"}}
    refute File.exists?(persist_path)
  end

  test "no open stream skips the form — straight to the header guidance" do
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
    assert text =~ "Authorization header"
    refute text =~ "mcp.env"

    # Exactly the one 401 attempt — nothing retried.
    assert_received {:api_call, "Bearer dead-token"}
    refute_received {:api_call, _header}
  end
end
