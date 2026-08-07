defmodule DoitMcp.HttpImportGateE2eTest do
  # async: false — boots the anubis HTTP tree under its real global registry
  # names and swaps the global :req_options app env.
  use ExUnit.Case, async: false

  import Plug.Test, only: [conn: 3]

  alias Anubis.Server.Transport.StreamableHTTP
  alias DoitMcp.ImportGate

  @moduletag :capture_log

  @threshold ImportGate.threshold()

  # The import gate's confirm over the resident HTTP transport (m03.04 items
  # 23.3 and 27.1), end-to-end through DoitMcp.Http.Plug against the real
  # tree: a gated batch returns PROMPTLY with the readback (never parking on
  # the transport's dispatch clock), the elicitation/create rides the
  # tripping session's OWN standalone stream (a second session's stream
  # stays clean), the operator's answer POST lands in the detached waiter,
  # and the re-call resolves — approve applies, decline reports. Without a
  # stream the gate holds loudly and immediately instead of hanging or
  # passing.

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

    # The gate's session memory under its production names, plus the real
    # HTTP tree the plug routes into.
    start_supervised!(DoitMcp.ImportGate.Counter)
    start_supervised!(DoitMcp.ImportGate.PendingConfirm)
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

  # Full handshake through the plug, advertising elicitation; returns the
  # server-assigned session id.
  defp handshake(headers) do
    initialize = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-06-18",
        "clientInfo" => %{"name" => "http-gate-e2e", "version" => "1.0"},
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

  # A stand-in for the standalone GET stream: registers with the transport
  # exactly as the plug's GET handler does and forwards every routed frame
  # to the test. The GET endpoint itself is stock anubis (the live smoke
  # covers it over the wire); this exercises the same session-scoped routing
  # without SSE wire parsing. Dies with the test via the link; the transport
  # monitors it and unregisters.
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

      # Keepalives and close signals are irrelevant to these assertions.
      _other ->
        stream_loop(test, session_id)
    end
  end

  # POST /operations reports each apply and echoes the created Initiative's
  # lid → real id; the task_count clause serves any pressure/style read.
  defp stub_api(test_pid) do
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
            Req.Test.json(conn, %{"data" => %{"count" => 0}})
        end
      end
    )
  end

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

  defp gated_call(id, readback) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{
        "name" => "apply_operations",
        "arguments" => %{
          "operations" => fresh_import_ops(@threshold + 1),
          "readback" => readback
        }
      }
    }
  end

  defp answer(elicitation_id, result, headers) do
    post_frame(%{"jsonrpc" => "2.0", "id" => elicitation_id, "result" => result}, headers)
  end

  # Answer the form through the plug, then await the detached waiter's exit
  # — the guarantee that the answer's session-memory effects landed before
  # the next POST.
  defp answer_form(session_id, elicitation_id, result, headers) do
    registry = Anubis.Server.Registry.registry_name(DoitMcp.Server)
    {:ok, session} = Anubis.Server.Registry.Local.lookup_session(registry, session_id)
    [{waiter, _value}] = Registry.lookup(DoitMcp.Elicitation.Registry, session)
    ref = Process.monitor(waiter)

    conn = answer(elicitation_id, result, headers)
    assert conn.status == 202
    assert_receive {:DOWN, ^ref, :process, ^waiter, _reason}, 2_000
  end

  defp tool_result(conn) do
    assert conn.status == 200
    assert %{"result" => result} = Jason.decode!(conn.resp_body)
    assert [%{"type" => "text", "text" => text} | rest] = result["content"]
    {result["isError"], Jason.decode!(text), rest}
  end

  test "a gated import returns the readback promptly, elicits on the tripping session's stream only, and applies on the approved re-call" do
    stub_api(self())

    alpha = [{"authorization", "Bearer token-alpha"}]
    beta = [{"authorization", "Bearer token-beta"}]
    session_a = handshake(alpha)
    session_b = handshake(beta)
    open_stream(session_a)
    open_stream(session_b)

    a_headers = [{"mcp-session-id", session_a} | alpha]
    readback = "Importing PLAN.md as #{@threshold + 1} tasks."

    # The gated call answers inside the dispatch bound — a NORMAL result
    # carrying the readback and the re-call contract, nothing applied.
    assert {false, decoded, _rest} = tool_result(post_frame(gated_call(2, readback), a_headers))
    assert decoded["status"] == "confirmation_pending"
    assert decoded["applied"] == false
    assert decoded["readback"] =~ "Importing PLAN.md"
    assert decoded["message"] =~ "operator_decision"
    refute_received :applied

    # The confirm form rides session A's stream out-of-band — and ONLY A's —
    # carrying the same message the result returned.
    assert_receive {:sse, ^session_a,
                    %{
                      "method" => "elicitation/create",
                      "id" => elicitation_id,
                      "params" => %{"message" => message, "requestedSchema" => schema}
                    }},
                   5_000

    assert message == decoded["readback"]
    assert schema["properties"]["decision"]["enum"] == ["apply", "correct", "hold"]
    refute_received {:sse, ^session_b, _frame}

    # The operator approves on the form; the session remembers, so the plain
    # re-call flows and applies.
    answer_form(
      session_a,
      elicitation_id,
      %{"action" => "accept", "content" => %{"decision" => "apply"}},
      a_headers
    )

    assert {false, decoded, _rest} = tool_result(post_frame(gated_call(3, readback), a_headers))
    assert decoded["ok"] == true
    assert_received :applied

    # Session B's stream stayed clean through the whole exchange.
    refute_received {:sse, ^session_b, _frame}
  end

  test "a declined confirm reports on the re-call and the batch stays unapplied" do
    stub_api(self())

    alpha = [{"authorization", "Bearer token-alpha"}]
    session = handshake(alpha)
    open_stream(session)
    headers = [{"mcp-session-id", session} | alpha]

    assert {false, decoded, _rest} =
             tool_result(post_frame(gated_call(2, "Importing PLAN.md."), headers))

    assert decoded["status"] == "confirmation_pending"

    assert_receive {:sse, ^session, %{"method" => "elicitation/create", "id" => elicitation_id}},
                   5_000

    answer_form(session, elicitation_id, %{"action" => "decline"}, headers)

    assert {true, decoded, _rest} =
             tool_result(post_frame(gated_call(3, "Importing PLAN.md."), headers))

    assert decoded["applied"] == false
    assert decoded["message"] =~ "declined"
    refute_received :applied
  end

  test "a capable session with no open stream is held loudly and immediately, never hung" do
    stub_api(self())

    alpha = [{"authorization", "Bearer token-alpha"}]
    session = handshake(alpha)
    headers = [{"mcp-session-id", session} | alpha]

    conn = post_frame(gated_call(2, "Importing PLAN.md."), headers)

    assert {true, decoded, _rest} = tool_result(conn)
    assert decoded["applied"] == false
    assert decoded["message"] =~ "no open server-to-client stream"
    assert decoded["message"] =~ "#{@threshold + 1} task-adds"
    refute_received :applied
  end
end
