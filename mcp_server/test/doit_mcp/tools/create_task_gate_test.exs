defmodule DoitMcp.CreateTaskGateTest.FakeSession do
  @moduledoc "Holds client_capabilities where DoitMcp.Elicitation reads them."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

  @impl true
  def init(opts) do
    {:ok, %{client_capabilities: opts[:capabilities], forward_to: opts[:forward_to]}}
  end
end

defmodule DoitMcp.CreateTaskGateTest do
  # The single-create cap (m03.04 3.1 iteration 2): create_task feeds the
  # batch gate's per-initiative session counter and refuses once the same
  # threshold is crossed one-by-one — the gate-evasion loop a baseline drive
  # narrated ("avoiding an unapplied bulk operation").
  use ExUnit.Case, async: false

  alias Anubis.Server.Response
  alias DoitMcp.CreateTaskGateTest.FakeSession
  alias DoitMcp.ImportGate
  alias DoitMcp.ImportGate.Counter
  alias DoitMcp.Tools.CreateTask

  @threshold ImportGate.threshold()
  @frame %{test: true}

  setup do
    Application.put_env(:doit_mcp, :import_gate_enabled, true)
    on_exit(fn -> Application.delete_env(:doit_mcp, :import_gate_enabled) end)
    :ok
  end

  defp start_counter do
    name = :"#{__MODULE__}.Counter"
    start_supervised!({Counter, name: name})

    previous = Application.fetch_env(:doit_mcp, :import_gate_counter)
    Application.put_env(:doit_mcp, :import_gate_counter, name)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:doit_mcp, :import_gate_counter, value)
        :error -> Application.delete_env(:doit_mcp, :import_gate_counter)
      end
    end)
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

  defp stub_create_ok do
    Req.Test.stub(DoitMcp.Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/api/v1/operations"} ->
          Req.Test.json(conn, %{"results" => [%{"status" => "ok", "data" => %{"id" => 1}}]})

        {"GET", "/api/v1/tasks/42"} ->
          Req.Test.json(conn, %{"data" => %{"id" => 42, "initiative_id" => 7}})
      end
    end)
  end

  defp decode(response) do
    protocol = Response.to_protocol(response)
    assert [%{"type" => "text", "text" => text} | _] = protocol["content"]
    {protocol, Jason.decode!(text)}
  end

  test "each committed single create records toward the destination's counter" do
    elicitation_capable()
    start_counter()
    stub_create_ok()

    assert {:reply, _response, @frame} =
             CreateTask.execute(%{initiative_id: 7, title: "One"}, @frame)

    assert Counter.cumulative({:existing, 7}) == 1
  end

  test "crossing the threshold one-by-one refuses and names the batch path" do
    elicitation_capable()
    start_counter()
    Counter.record([{{:existing, 7}, @threshold}])

    assert {:reply, response, @frame} =
             CreateTask.execute(%{initiative_id: 7, title: "One too many"}, @frame)

    {protocol, decoded} = decode(response)
    assert protocol["isError"] == true
    assert decoded["gate"] == "single_create_cap"
    assert decoded["message"] =~ "created #{@threshold} tasks"
    assert decoded["message"] =~ "apply_operations"
    # Refused creates record nothing.
    assert Counter.cumulative({:existing, 7}) == @threshold
  end

  test "a parent-anchored create resolves its initiative through the task read" do
    elicitation_capable()
    start_counter()
    Counter.record([{{:existing, 7}, @threshold}])
    stub_create_ok()

    assert {:reply, response, @frame} =
             CreateTask.execute(%{parent_id: 42, title: "Nested dodge"}, @frame)

    {protocol, _decoded} = decode(response)
    assert protocol["isError"] == true
  end

  test "an operator-confirmed initiative flows freely past the cap" do
    elicitation_capable()
    start_counter()
    Counter.record([{{:existing, 7}, @threshold}])
    Counter.mark_confirmed({:existing, 7})
    stub_create_ok()

    assert {:reply, response, @frame} =
             CreateTask.execute(%{initiative_id: 7, title: "Sanctioned"}, @frame)

    {protocol, _decoded} = decode(response)
    assert protocol["isError"] == false
    assert Counter.cumulative({:existing, 7}) == @threshold + 1
  end

  test "the cap stands aside without elicitation capability" do
    fake_session(%{})
    start_counter()
    Counter.record([{{:existing, 7}, @threshold}])
    stub_create_ok()

    assert {:reply, response, @frame} =
             CreateTask.execute(%{initiative_id: 7, title: "Ungated client"}, @frame)

    {protocol, _decoded} = decode(response)
    assert protocol["isError"] == false
    # And records nothing — mirrors the batch side's capability skip.
    assert Counter.cumulative({:existing, 7}) == @threshold
  end

  test "the kill switch disarms the cap" do
    Application.put_env(:doit_mcp, :import_gate_enabled, false)
    elicitation_capable()
    start_counter()
    Counter.record([{{:existing, 7}, @threshold}])
    stub_create_ok()

    assert {:reply, response, @frame} =
             CreateTask.execute(%{initiative_id: 7, title: "Disarmed"}, @frame)

    {protocol, _decoded} = decode(response)
    assert protocol["isError"] == false
  end
end
