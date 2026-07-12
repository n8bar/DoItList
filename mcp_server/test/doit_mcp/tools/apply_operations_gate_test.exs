defmodule DoitMcp.ApplyOperationsGateTest.FakeSession do
  @moduledoc """
  Stands in for the Anubis session process in gate tests: holds
  `client_capabilities` where `DoitMcp.Elicitation` reads them
  (`:sys.get_state/1`) and forwards `{:send_elicitation_request, ...}` info
  messages to the test process so it can play the operator.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

  @impl true
  def init(opts) do
    {:ok, %{client_capabilities: opts[:capabilities], forward_to: opts[:forward_to]}}
  end

  @impl true
  def handle_info({:send_elicitation_request, _params, _schema, _timeout} = msg, state) do
    send(state.forward_to, msg)
    {:noreply, state}
  end
end

defmodule DoitMcp.ApplyOperationsGateTest do
  use ExUnit.Case, async: false

  alias Anubis.Server.Response
  alias DoitMcp.ApplyOperationsGateTest.FakeSession
  alias DoitMcp.{Elicitation, ImportGate}
  alias DoitMcp.Tools.ApplyOperations

  @threshold ImportGate.threshold()
  @frame %{test: true}

  # The gate ships dark (DOITLIST_IMPORT_GATE=on arms it); arm it for these
  # behavior tests.
  setup do
    Application.put_env(:doit_mcp, :import_gate_enabled, true)
    on_exit(fn -> Application.delete_env(:doit_mcp, :import_gate_enabled) end)
    :ok
  end

  defp fake_session(capabilities) do
    name = :"#{__MODULE__}.FakeSession"
    start_supervised!({FakeSession, name: name, capabilities: capabilities, forward_to: self()})

    previous = Application.fetch_env(:doit_mcp, :elicitation_session_name)
    Application.put_env(:doit_mcp, :elicitation_session_name, name)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:doit_mcp, :elicitation_session_name, value)
        :error -> Application.delete_env(:doit_mcp, :elicitation_session_name)
      end
    end)
  end

  defp elicitation_capable, do: fake_session(%{"elicitation" => %{}})

  defp new_initiative_batch(task_count) do
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

  defp existing_initiative_batch(task_count, initiative_id) do
    for i <- 1..task_count do
      %{
        "op" => "add",
        "type" => "task",
        "lid" => "t#{i}",
        "data" => %{"initiative_id" => initiative_id, "title" => "task #{i}"}
      }
    end
  end

  defp stub_apply_ok do
    Req.Test.stub(DoitMcp.Client, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/v1/operations"
      Req.Test.json(conn, %{"results" => []})
    end)
  end

  defp decode_json_content(response) do
    protocol = Response.to_protocol(response)
    assert [%{"type" => "text", "text" => text} | rest] = protocol["content"]
    {protocol, Jason.decode!(text), rest}
  end

  test "a batch at the threshold applies straight through, no elicitation" do
    elicitation_capable()
    stub_apply_ok()

    ops = new_initiative_batch(@threshold)
    assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: ops}, @frame)

    {protocol, decoded, _} = decode_json_content(response)
    assert protocol["isError"] == false
    assert decoded["ok"] == true
    refute_received {:send_elicitation_request, _, _, _}
  end

  test "a client without the elicitation capability skips the gate entirely" do
    fake_session(%{"sampling" => %{}})
    stub_apply_ok()

    ops = new_initiative_batch(@threshold + 1)
    refute Elicitation.client_supports_elicitation?()

    assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: ops}, @frame)
    {_, decoded, _} = decode_json_content(response)
    assert decoded["ok"] == true
    refute_received {:send_elicitation_request, _, _, _}
  end

  test "gated batch without readback is rejected unapplied, telling the agent what to supply" do
    elicitation_capable()

    ops = new_initiative_batch(@threshold + 1)
    assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: ops}, @frame)

    protocol = Response.to_protocol(response)
    assert protocol["isError"] == true
    assert [%{"type" => "text", "text" => text}] = protocol["content"]
    assert text =~ "readback"
    assert text =~ "assumptions"
    assert text =~ "#{@threshold + 1} tasks"
    refute_received {:send_elicitation_request, _, _, _}
  end

  test "operator confirm applies the batch and appends the ai_knobs note" do
    elicitation_capable()
    stub_apply_ok()

    ops = new_initiative_batch(@threshold + 1)
    readback = "Importing PLAN.md as 31 tasks under one new Initiative, two levels deep."
    assumptions = ["Depth taken from markdown heading levels", "Struck-through items skipped"]

    task =
      Task.async(fn ->
        ApplyOperations.execute(
          %{operations: ops, readback: readback, assumptions: assumptions},
          @frame
        )
      end)

    assert_receive {:send_elicitation_request, params, schema, timeout}, 2_000

    # Message: readback verbatim, assumptions as a list, then the confirm line.
    assert params["message"] ==
             readback <>
               "\n\nAssumptions:\n- Depth taken from markdown heading levels\n" <>
               "- Struck-through items skipped\n\n" <>
               "Confirm to apply this import, or supply corrections."

    assert params["requestedSchema"] == schema
    assert %{"type" => "object", "required" => ["confirm"], "properties" => props} = schema
    assert props["confirm"]["type"] == "boolean"
    assert props["corrections"]["type"] == "string"
    assert timeout == to_timeout(minute: 5)

    Elicitation.deliver(%{"action" => "accept", "content" => %{"confirm" => true}})

    assert {:reply, response, @frame} = Task.await(task, 5_000)
    {protocol, decoded, rest} = decode_json_content(response)
    assert protocol["isError"] == false
    assert decoded["ok"] == true
    assert [%{"type" => "text", "text" => note}] = rest
    assert note =~ "ai_knobs"
  end

  test "corrections come back as the tool result and nothing applies" do
    elicitation_capable()

    task =
      Task.async(fn ->
        ApplyOperations.execute(
          %{operations: new_initiative_batch(@threshold + 1), readback: "Importing 31 tasks."},
          @frame
        )
      end)

    assert_receive {:send_elicitation_request, params, _schema, _timeout}, 2_000
    assert params["message"] =~ "Assumptions: none stated."

    Elicitation.deliver(%{
      "action" => "accept",
      "content" => %{"confirm" => true, "corrections" => "Milestones as top-level tasks"}
    })

    assert {:reply, response, @frame} = Task.await(task, 5_000)
    {protocol, decoded, _} = decode_json_content(response)
    assert protocol["isError"] == true
    assert decoded["applied"] == false
    assert decoded["corrections"] == "Milestones as top-level tasks"
  end

  test "confirm=false without corrections holds the batch" do
    elicitation_capable()

    task =
      Task.async(fn ->
        ApplyOperations.execute(
          %{operations: new_initiative_batch(@threshold + 1), readback: "Importing 31 tasks."},
          @frame
        )
      end)

    assert_receive {:send_elicitation_request, _, _, _}, 2_000
    Elicitation.deliver(%{"action" => "accept", "content" => %{"confirm" => false}})

    assert {:reply, response, @frame} = Task.await(task, 5_000)
    {protocol, decoded, _} = decode_json_content(response)
    assert protocol["isError"] == true
    assert decoded["applied"] == false
    assert decoded["message"] =~ "confirm=false"
  end

  test "decline and cancel both hold the batch" do
    elicitation_capable()
    ops = new_initiative_batch(@threshold + 1)

    for {action, expected} <- [{"decline", "declined"}, {"cancel", "did not respond"}] do
      task =
        Task.async(fn ->
          ApplyOperations.execute(%{operations: ops, readback: "Importing 31 tasks."}, @frame)
        end)

      assert_receive {:send_elicitation_request, _, _, _}, 2_000
      Elicitation.deliver(%{"action" => action})

      assert {:reply, response, @frame} = Task.await(task, 5_000)
      {_, decoded, _} = decode_json_content(response)
      assert decoded["applied"] == false
      assert decoded["message"] =~ expected
    end
  end

  test "no answer within the window holds the batch" do
    elicitation_capable()
    Application.put_env(:doit_mcp, :import_gate_confirm_timeout, 10)
    on_exit(fn -> Application.delete_env(:doit_mcp, :import_gate_confirm_timeout) end)

    task =
      Task.async(fn ->
        ApplyOperations.execute(
          %{operations: new_initiative_batch(@threshold + 1), readback: "Importing 31 tasks."},
          @frame
        )
      end)

    assert_receive {:send_elicitation_request, _, _, 10}, 2_000

    assert {:reply, response, @frame} = Task.await(task, 5_000)
    {_, decoded, _} = decode_json_content(response)
    assert decoded["applied"] == false
    assert decoded["message"] =~ "did not respond"
  end

  test "an existing target's ai_knobs is fetched over the API; settled knobs pass" do
    elicitation_capable()

    Req.Test.stub(DoitMcp.Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/v1/initiatives/7"} ->
          Req.Test.json(conn, %{"data" => %{"id" => 7, "ai_knobs" => "deploy_day: friday"}})

        {"POST", "/api/v1/operations"} ->
          Req.Test.json(conn, %{"results" => []})
      end
    end)

    ops = existing_initiative_batch(@threshold + 1, 7)
    assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: ops}, @frame)

    {_, decoded, _} = decode_json_content(response)
    assert decoded["ok"] == true
    refute_received {:send_elicitation_request, _, _, _}
  end

  test "an existing target with empty ai_knobs gates" do
    elicitation_capable()

    Req.Test.stub(DoitMcp.Client, fn conn ->
      assert {conn.method, conn.request_path} == {"GET", "/api/v1/initiatives/7"}
      Req.Test.json(conn, %{"data" => %{"id" => 7, "ai_knobs" => nil}})
    end)

    ops = existing_initiative_batch(@threshold + 1, 7)
    assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: ops}, @frame)

    assert Response.to_protocol(response)["isError"] == true
    refute_received {:send_elicitation_request, _, _, _}
  end
end
