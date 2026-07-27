defmodule DoitMcp.HttpImportGateSessionsTest do
  # async: false — boots the anubis HTTP tree under its real global registry
  # names and swaps the global :req_options app env.
  use ExUnit.Case, async: false

  import Plug.Test, only: [conn: 3]

  alias Anubis.Server.Transport.StreamableHTTP
  alias DoitMcp.ImportGate

  @moduletag :capture_log

  @threshold ImportGate.threshold()

  # Gate state per session on the resident transport (m03.04 item 23.6). One
  # VM serves every connected client, so the confirm memory has to be keyed:
  # the operator's confirm settles an Initiative for the session that granted
  # it and for no other. Recent-creation PRESSURE is deliberately not session
  # state — it is the database's window (3.1 iteration 2), shared by design —
  # so a second session sees it in full.

  setup do
    Application.put_env(:doit_mcp, :import_gate_enabled, true)
    previous_req = Application.fetch_env(:doit_mcp, :req_options)

    on_exit(fn ->
      Application.delete_env(:doit_mcp, :import_gate_enabled)

      case previous_req do
        {:ok, value} -> Application.put_env(:doit_mcp, :req_options, value)
        :error -> Application.delete_env(:doit_mcp, :req_options)
      end
    end)

    start_supervised!(DoitMcp.ImportGate.Counter)
    start_supervised!({DoitMcp.Server, transport: {:streamable_http, start: true}})
    :ok
  end

  # Computed per call — 1.10's Plug.init/1 embeds a local-function capture
  # that cannot be escaped into a module attribute.
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
        "clientInfo" => %{"name" => "http-gate-sessions", "version" => "1.0"},
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

  # POST /operations reports each apply and echoes the created Initiative's
  # lid → real id; the GET clause serves the database's pressure window at
  # `count` (no initiative_created_at — the target reads as aged, so the
  # normal bounds apply).
  defp stub_api(test_pid, count \\ 0) do
    Application.put_env(:doit_mcp, :req_options,
      plug: fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/api/v1/operations"} ->
            send(test_pid, :applied)

            Req.Test.json(conn, %{
              "results" => [
                %{"index" => 0, "lid" => "i", "status" => "ok", "data" => %{"id" => 57}}
              ]
            })

          {"GET", _task_count} ->
            Req.Test.json(conn, %{"data" => %{"count" => count}})
        end
      end
    )
  end

  # A new Initiative plus its first tasks, referenced by lid.
  defp fresh_import_ops(task_count) do
    [%{"op" => "add", "type" => "initiative", "lid" => "i", "data" => %{"name" => "Import"}}] ++
      for i <- 1..task_count do
        %{
          "op" => "add",
          "type" => "task",
          "lid" => "t#{i}",
          "data" => %{"initiative_lid" => "i", "title" => "task #{i}"}
        }
      end
  end

  # The same import continued by real id — what every later chunk looks like.
  defp chunk_ops(task_count, initiative_id) do
    for i <- 1..task_count do
      %{
        "op" => "add",
        "type" => "task",
        "lid" => "t#{i}",
        "data" => %{"initiative_id" => initiative_id, "title" => "task #{i}"}
      }
    end
  end

  defp tools_call(id, arguments) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => "apply_operations", "arguments" => arguments}
    }
  end

  defp answer(elicitation_id, result, headers) do
    post_frame(%{"jsonrpc" => "2.0", "id" => elicitation_id, "result" => result}, headers)
  end

  defp tool_result(conn) do
    {is_error, text, rest} = tool_text(conn)
    {is_error, Jason.decode!(text), rest}
  end

  # The readback-required refusal is prose, not the JSON payload the applied
  # and held answers carry.
  defp tool_text(conn) do
    assert conn.status == 200
    assert %{"result" => result} = Jason.decode!(conn.resp_body)
    assert [%{"type" => "text", "text" => text} | rest] = result["content"]
    {result["isError"], text, rest}
  end

  # Fire a tools/call that will park on the confirm form, so the test can
  # answer it while the call is still open.
  defp held_call(message, headers) do
    Task.async(fn -> post_frame(message, headers) end)
  end

  test "one session's confirm settles that session only" do
    stub_api(self())

    alpha = [{"authorization", "Bearer token-alpha"}]
    beta = [{"authorization", "Bearer token-beta"}]
    session_a = handshake(alpha)
    session_b = handshake(beta)
    open_stream(session_a)
    open_stream(session_b)

    a_headers = [{"mcp-session-id", session_a} | alpha]
    b_headers = [{"mcp-session-id", session_b} | beta]

    call =
      held_call(
        tools_call(2, %{
          "operations" => fresh_import_ops(@threshold + 1),
          "readback" => "Importing PLAN.md as #{@threshold + 1} tasks."
        }),
        a_headers
      )

    assert_receive {:sse, ^session_a, %{"method" => "elicitation/create", "id" => a_elicit}},
                   5_000

    conn =
      answer(a_elicit, %{"action" => "accept", "content" => %{"decision" => "apply"}}, a_headers)

    assert conn.status == 202

    assert {false, decoded, _rest} = tool_result(Task.await(call, 10_000))
    assert decoded["ok"] == true
    assert_received :applied

    # Session B continues the SAME import by the real id A's confirm was
    # carried to — and is held on its own stream: it answered nothing.
    b_call =
      held_call(
        tools_call(2, %{
          "operations" => chunk_ops(@threshold + 1, 57),
          "readback" => "Importing the rest of PLAN.md."
        }),
        b_headers
      )

    assert_receive {:sse, ^session_b, %{"method" => "elicitation/create", "id" => b_elicit}},
                   5_000

    conn = answer(b_elicit, %{"action" => "decline"}, b_headers)
    assert conn.status == 202

    assert {true, decoded, _rest} = tool_result(Task.await(b_call, 10_000))
    assert decoded["applied"] == false
    assert decoded["message"] =~ "declined"
    refute_received :applied

    # And A's own confirm still stands for the rest of A's session — the
    # single-session semantics are unchanged: no second form, straight apply.
    assert {false, decoded, _rest} =
             tool_result(
               post_frame(
                 tools_call(3, %{"operations" => chunk_ops(@threshold + 1, 57)}),
                 a_headers
               )
             )

    assert decoded["ok"] == true
    assert_received :applied
    refute_received {:sse, ^session_a, _frame}
  end

  test "a decline latches nothing — the grantor re-elicits and a second session is untouched" do
    stub_api(self())

    alpha = [{"authorization", "Bearer token-alpha"}]
    beta = [{"authorization", "Bearer token-beta"}]
    session_a = handshake(alpha)
    session_b = handshake(beta)
    open_stream(session_a)
    open_stream(session_b)

    a_headers = [{"mcp-session-id", session_a} | alpha]
    b_headers = [{"mcp-session-id", session_b} | beta]

    gated = %{
      "operations" => fresh_import_ops(@threshold + 1),
      "readback" => "Importing PLAN.md as #{@threshold + 1} tasks."
    }

    call = held_call(tools_call(2, gated), a_headers)
    assert_receive {:sse, ^session_a, %{"method" => "elicitation/create", "id" => first}}, 5_000
    assert answer(first, %{"action" => "decline"}, a_headers).status == 202
    assert {true, decoded, _rest} = tool_result(Task.await(call, 10_000))
    assert decoded["applied"] == false

    # Nothing latched on A: the same batch asks again.
    call = held_call(tools_call(3, gated), a_headers)
    assert_receive {:sse, ^session_a, %{"method" => "elicitation/create", "id" => second}}, 5_000
    assert second != first
    assert answer(second, %{"action" => "decline"}, a_headers).status == 202
    assert {true, _decoded, _rest} = tool_result(Task.await(call, 10_000))

    # And nothing latched on B either — its own form, on its own stream.
    call = held_call(tools_call(2, gated), b_headers)

    assert_receive {:sse, ^session_b, %{"method" => "elicitation/create", "id" => b_elicit}},
                   5_000

    assert answer(b_elicit, %{"action" => "decline"}, b_headers).status == 202
    assert {true, _decoded, _rest} = tool_result(Task.await(call, 10_000))

    refute_received :applied
  end

  test "recent-creation pressure crosses sessions — it is the database's window, not the VM's" do
    # 200 tasks already landed in Initiative 57 inside the window, none of
    # them by this session.
    stub_api(self(), 200)

    beta = [{"authorization", "Bearer token-beta"}]
    session = handshake(beta)
    open_stream(session)
    headers = [{"mcp-session-id", session} | beta]

    assert {true, text, _rest} =
             tool_text(post_frame(tools_call(2, %{"operations" => chunk_ops(1, 57)}), headers))

    assert text =~ "201 this session"
    refute_received :applied
  end
end
