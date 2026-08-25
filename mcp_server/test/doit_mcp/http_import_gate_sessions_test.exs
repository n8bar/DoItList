defmodule DoitMcp.HttpImportGateSessionsTest do
  # async: false — boots the anubis HTTP tree under its real global registry
  # names and swaps the global :req_options app env.
  use ExUnit.Case, async: false

  import Plug.Test, only: [conn: 3]

  alias DoitMcp.ImportGate

  @moduletag :capture_log

  @threshold ImportGate.threshold()

  # Record state per session on the resident transport (m03.04 items 23.6 and
  # 36). One VM serves every connected client, so the readback-record memory
  # has to be keyed: a recorded import settles an Initiative for the session
  # that recorded it and for no other. Recent-creation PRESSURE is
  # deliberately not session state — it is the database's window (3.1
  # iteration 2), shared by design — so a second session sees it in full.

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
        "capabilities" => %{}
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

  # POST /operations reports each apply — a record comment post reports as
  # {:applied, [comment_op]}, so tests can tell the batch from its record —
  # and echoes a created Initiative's lid → real id + root_task_id; the GET
  # clauses serve the database's pressure window at `count` and the
  # initiative list (the record's root lookup for existing targets).
  defp stub_api(test_pid, count \\ 0) do
    Application.put_env(:doit_mcp, :req_options,
      plug: fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/api/v1/operations"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            ops = Jason.decode!(body)["operations"] || []
            send(test_pid, {:applied, ops})

            Req.Test.json(conn, %{
              "results" => [
                %{
                  "index" => 0,
                  "lid" => "i",
                  "status" => "ok",
                  "data" => %{"id" => 57, "type" => "initiative", "root_task_id" => 570}
                }
              ]
            })

          {"POST", "/api/v1/import_declarations"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            Req.Test.json(conn, %{"data" => Jason.decode!(body)})

          {"GET", "/api/v1/initiatives"} ->
            Req.Test.json(conn, %{"data" => [%{"id" => 57, "root_task_id" => 570}]})

          {"GET", _task_count} ->
            Req.Test.json(conn, %{"data" => %{"count" => count}})
        end
      end
    )
  end

  # A new Initiative plus its first tasks, referenced by lid. The first task
  # arrives done, so the whole-import declaration below is 1-complete.
  defp fresh_import_ops(task_count) do
    [%{"op" => "add", "type" => "initiative", "lid" => "i", "data" => %{"name" => "Import"}}] ++
      for i <- 1..task_count do
        data = %{"initiative_lid" => "i", "title" => "task #{i}"}
        data = if i == 1, do: Map.put(data, "done", true), else: data
        %{"op" => "add", "type" => "task", "lid" => "t#{i}", "data" => data}
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

  defp tool_result(conn) do
    assert conn.status == 200
    assert %{"result" => result} = Jason.decode!(conn.resp_body)
    assert [%{"type" => "text", "text" => text} | rest] = result["content"]
    {result["isError"], Jason.decode!(text), rest}
  end

  defp assert_batch_applied do
    assert_receive {:applied, [%{"type" => type} | _]}, 2_000
    refute type == "comment"
  end

  defp assert_record_posted(prefix \\ "Import record — readback as applied:") do
    assert_receive {:applied, [%{"type" => "comment", "data" => %{"body" => body}}]}, 2_000
    assert body =~ prefix
    body
  end

  test "one session's record settles that session only" do
    stub_api(self())

    alpha = [{"authorization", "Bearer token-alpha"}]
    beta = [{"authorization", "Bearer token-beta"}]
    session_a = handshake(alpha)
    session_b = handshake(beta)

    a_headers = [{"mcp-session-id", session_a} | alpha]
    b_headers = [{"mcp-session-id", session_b} | beta]

    ops = fresh_import_ops(@threshold + 1)

    # A's bootstrap is a FIRST import (2.8.10): without a declaration it
    # meets the agent-facing demand — no stop, no operator step.
    assert {true, decoded, _rest} =
             tool_result(post_frame(tools_call(2, %{"operations" => ops}), a_headers))

    assert decoded["gate"] == "import_declaration"
    refute_received {:applied, _ops}

    # With the declaration it applies straight through — no prose readback
    # demanded (the declaration is the record) — and the record lands on
    # the created Initiative's root.
    gated = %{
      "operations" => ops,
      "declared_sources" => [%{"path" => "PLAN.md", "checkbox_lines" => @threshold + 1}],
      "declared_total" => @threshold + 1,
      "declared_completed" => 1,
      "declared_ordering" => "none"
    }

    assert {false, decoded, _rest} = tool_result(post_frame(tools_call(3, gated), a_headers))
    assert decoded["ok"] == true
    assert_batch_applied()
    assert_record_posted("Import record — declaration as accepted:")

    # A's record follows the Initiative to its real id: the next over-bound
    # chunk flows with no readback and posts no second record.
    assert {false, decoded, _rest} =
             tool_result(
               post_frame(
                 tools_call(4, %{"operations" => chunk_ops(@threshold + 1, 57)}),
                 a_headers
               )
             )

    assert decoded["ok"] == true
    assert_batch_applied()
    refute_received {:applied, _ops}

    # Session B continues the SAME import — but it recorded nothing, so its
    # over-bound chunk is refused until it states its own readback.
    assert {true, decoded, _rest} =
             tool_result(
               post_frame(
                 tools_call(2, %{"operations" => chunk_ops(@threshold + 1, 57)}),
                 b_headers
               )
             )

    assert decoded["gate"] == "import_readback"
    refute_received {:applied, _ops}

    b_gated = %{
      "operations" => chunk_ops(@threshold + 1, 57),
      "readback" => "Importing the rest of PLAN.md."
    }

    assert {false, decoded, _rest} = tool_result(post_frame(tools_call(3, b_gated), b_headers))
    assert decoded["ok"] == true
    assert_batch_applied()
    assert_record_posted()
  end

  test "recent-creation pressure crosses sessions — it is the database's window, not the VM's" do
    # 200 tasks already landed in Initiative 57 inside the window, none of
    # them by this session.
    stub_api(self(), 200)

    beta = [{"authorization", "Bearer token-beta"}]
    session = handshake(beta)
    headers = [{"mcp-session-id", session} | beta]

    assert {true, decoded, _rest} =
             tool_result(post_frame(tools_call(2, %{"operations" => chunk_ops(1, 57)}), headers))

    assert decoded["gate"] == "import_readback"
    assert decoded["message"] =~ "201 this session"
    refute_received {:applied, _ops}
  end
end
