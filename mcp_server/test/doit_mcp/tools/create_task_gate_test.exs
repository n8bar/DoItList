defmodule DoitMcp.CreateTaskGateTest.FakeSession do
  @moduledoc "Holds client_capabilities where DoitMcp.Elicitation reads them."
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

defmodule DoitMcp.CreateTaskGateTest do
  # The single-create pause (m03.04 3.1 iteration 2): pressure is the
  # DATABASE's recent-creation window (DoitMcp.ImportPressure) — a drip
  # decays, a loop accumulates — and past the threshold the tool pauses
  # agent-facing, never asking the operator anything.
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

  # The window count comes from the API; POST creates; GET /tasks/42 resolves
  # a parent anchor. `pressure` seeds the initiative's recent-creation count.
  defp stub_api(pressure) do
    test_pid = self()

    Req.Test.stub(DoitMcp.Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/v1/initiatives/7/task_count"} ->
          assert conn.query_string =~ "created_at="
          Req.Test.json(conn, %{"data" => %{"count" => pressure}})

        {"GET", "/api/v1/tasks/42"} ->
          Req.Test.json(conn, %{"data" => %{"id" => 42, "initiative_id" => 7}})

        {"POST", "/api/v1/operations"} ->
          send(test_pid, :created)
          Req.Test.json(conn, %{"results" => [%{"status" => "ok", "data" => %{"id" => 1}}]})
      end
    end)
  end

  defp decode(response) do
    protocol = Response.to_protocol(response)
    assert [%{"type" => "text", "text" => text} | _] = protocol["content"]
    {protocol, Jason.decode!(text)}
  end

  test "under the window's threshold a single create flows" do
    elicitation_capable()
    stub_api(@threshold - 5)

    assert {:reply, response, @frame} =
             CreateTask.execute(%{initiative_id: 7, title: "One"}, @frame)

    {protocol, _decoded} = decode(response)
    assert protocol["isError"] == false
    assert_received :created
  end

  test "past the threshold the pause names the window and the batch path — no operator question" do
    elicitation_capable()
    stub_api(@threshold)

    assert {:reply, response, @frame} =
             CreateTask.execute(%{initiative_id: 7, title: "One too many"}, @frame)

    {protocol, decoded} = decode(response)
    assert protocol["isError"] == true
    assert decoded["gate"] == "single_create_pause"
    assert decoded["message"] =~ "#{@threshold} tasks have landed"
    assert decoded["message"] =~ "minutes"
    assert decoded["message"] =~ "apply_operations"
    assert decoded["message"] =~ "one list at a time"
    refute_received {:send_elicitation_request, _, _, _}
    refute_received :created
  end

  test "a parent-anchored create resolves its initiative and pauses past the threshold" do
    elicitation_capable()
    stub_api(@threshold + 3)

    assert {:reply, response, @frame} =
             CreateTask.execute(%{parent_id: 42, title: "Nested"}, @frame)

    {protocol, _decoded} = decode(response)
    assert protocol["isError"] == true
    refute_received :created
  end

  test "an operator-confirmed initiative flows freely past any pressure" do
    elicitation_capable()
    start_counter()
    Counter.mark_confirmed({:existing, 7})
    stub_api(@threshold + 100)

    assert {:reply, response, @frame} =
             CreateTask.execute(%{initiative_id: 7, title: "Sanctioned"}, @frame)

    {protocol, _decoded} = decode(response)
    assert protocol["isError"] == false
    assert_received :created
  end

  test "the pause stands aside without elicitation capability" do
    fake_session(%{})
    stub_api(@threshold + 100)

    assert {:reply, response, @frame} =
             CreateTask.execute(%{initiative_id: 7, title: "Ungated client"}, @frame)

    {protocol, _decoded} = decode(response)
    assert protocol["isError"] == false
    assert_received :created
  end

  test "the kill switch disarms the pause" do
    Application.put_env(:doit_mcp, :import_gate_enabled, false)
    elicitation_capable()
    stub_api(@threshold + 100)

    assert {:reply, response, @frame} =
             CreateTask.execute(%{initiative_id: 7, title: "Disarmed"}, @frame)

    {protocol, _decoded} = decode(response)
    assert protocol["isError"] == false
    assert_received :created
  end
end
