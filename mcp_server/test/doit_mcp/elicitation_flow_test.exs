defmodule DoitMcp.ElicitationFlowTest do
  use ExUnit.Case, async: false

  alias DoitMcp.ImportGate

  # Session logs its lifecycle; keep test output clean.
  @moduletag :capture_log

  # Proves the import gate's elicitation round trip through a REAL
  # Anubis.Server.Session — initialize handshake advertising the elicitation
  # capability, tools/call dispatch, the outbound elicitation/create, the
  # client's answer routed back through DoitMcp.Server.handle_elicitation/3,
  # and the parked tool resuming with the operator's decision. The test
  # process stands in as the transport (STDIO's send_message/3 is a
  # GenServer.call it can answer directly); the same flow over the real
  # concurrent transport lives in DoitMcp.StdioTransportTest.

  # The gate ships armed (DOITLIST_IMPORT_GATE=off opts out); pin it on for
  # determinism against the container's ambient environment.
  setup do
    Application.put_env(:doit_mcp, :import_gate_enabled, true)
    on_exit(fn -> Application.delete_env(:doit_mcp, :import_gate_enabled) end)
    :ok
  end

  test "a gated apply_operations round-trips operator corrections through a real session" do
    session_name = :"#{__MODULE__}.Session"
    transport_name = :"#{__MODULE__}.Transport"
    task_sup = :"#{__MODULE__}.TaskSup"

    Process.register(self(), transport_name)
    start_supervised!({Task.Supervisor, name: task_sup})

    start_supervised!(
      {Anubis.Server.Session,
       session_id: "elicitation-flow-test",
       server_module: DoitMcp.Server,
       name: session_name,
       transport: [layer: Anubis.Server.Transport.STDIO, name: transport_name],
       task_supervisor: task_sup}
    )

    previous = Application.fetch_env(:doit_mcp, :elicitation_session_name)
    Application.put_env(:doit_mcp, :elicitation_session_name, session_name)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:doit_mcp, :elicitation_session_name, value)
        :error -> Application.delete_env(:doit_mcp, :elicitation_session_name)
      end
    end)

    session = Process.whereis(session_name)

    # 1. Initialize handshake — the client advertises elicitation support.
    initialize = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-06-18",
        "clientInfo" => %{"name" => "flow-test", "version" => "1.0"},
        "capabilities" => %{"elicitation" => %{}}
      }
    }

    assert {:ok, _reply} = GenServer.call(session, {:mcp_request, initialize, %{}})

    initialized = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
    GenServer.cast(session, {:mcp_notification, initialized, %{}})
    _ = :sys.get_state(session)

    assert DoitMcp.Elicitation.client_supports_elicitation?()

    # 2. A gated batch: a new Initiative plus threshold+1 task adds.
    operations =
      [%{"op" => "add", "type" => "initiative", "lid" => "i", "data" => %{"name" => "Import"}}] ++
        for i <- 1..(ImportGate.threshold() + 1) do
          %{
            "op" => "add",
            "type" => "task",
            "lid" => "t#{i}",
            "data" => %{"initiative_lid" => "i", "title" => "task #{i}"}
          }
        end

    tools_call = %{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "tools/call",
      "params" => %{
        "name" => "apply_operations",
        "arguments" => %{
          "operations" => operations,
          "readback" => "Importing PLAN.md as 31 tasks under one new Initiative.",
          "assumptions" => ["Depth taken from markdown heading levels"]
        }
      }
    }

    call = Task.async(fn -> GenServer.call(session, {:mcp_request, tools_call, %{}}, 15_000) end)

    # 3. The session sends elicitation/create out through the transport (us).
    assert_receive {:"$gen_call", from, {:send, wire}}, 5_000
    GenServer.reply(from, :ok)

    assert %{
             "method" => "elicitation/create",
             "id" => request_id,
             "params" => %{"message" => message, "requestedSchema" => schema}
           } = Jason.decode!(wire)

    assert message =~ "Importing PLAN.md as 31 tasks"
    assert message =~ "- Depth taken from markdown heading levels"
    assert message =~ "Confirm to apply this import, or supply corrections."
    assert schema["required"] == ["confirm"]

    # 4. The operator supplies corrections — Anubis validates the content
    # against the requested schema, dispatches handle_elicitation, and the
    # parked tool resumes: batch NOT applied (an apply would hit the missing
    # HTTP stub and fail loudly), corrections in the tool result.
    answer = %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "result" => %{
        "action" => "accept",
        "content" => %{"confirm" => false, "corrections" => "Milestones as top-level tasks"}
      }
    }

    assert {:ok, nil} = GenServer.call(session, {:mcp_request, answer, %{}})

    assert {:ok, reply} = Task.await(call, 15_000)
    assert %{"result" => result} = Jason.decode!(reply)
    assert result["isError"] == true
    assert [%{"type" => "text", "text" => text}] = result["content"]

    decoded = Jason.decode!(text)
    assert decoded["applied"] == false
    assert decoded["corrections"] == "Milestones as top-level tasks"
  end
end
