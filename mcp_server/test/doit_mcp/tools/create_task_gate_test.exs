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
  # agent-facing, never asking the operator anything. The fresh floor
  # (iteration 3) applies here too: a just-created Initiative pauses singles
  # past fresh_threshold toward the batch path's confirm, so the per-op path
  # can't drip past the floor one task at a time.
  use ExUnit.Case, async: false

  alias Anubis.Server.Response
  alias DoitMcp.CreateTaskGateTest.FakeSession
  alias DoitMcp.ImportGate
  alias DoitMcp.ImportGate.Counter
  alias DoitMcp.ImportPressure
  alias DoitMcp.Tools.CreateTask

  @threshold ImportGate.threshold()
  @fresh_floor ImportGate.fresh_threshold()
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
  # a parent anchor. `pressure` seeds the initiative's recent-creation count;
  # `initiative_created_at` (optional — omitting it is the pre-iteration-3
  # response shape, which fails open to the normal threshold) rides the SAME
  # response, and :pressure_read lets tests pin the one-read doctrine.
  defp stub_api(pressure, initiative_created_at \\ nil) do
    test_pid = self()

    data =
      if initiative_created_at,
        do: %{"count" => pressure, "initiative_created_at" => initiative_created_at},
        else: %{"count" => pressure}

    Req.Test.stub(DoitMcp.Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/v1/initiatives/7/task_count"} ->
          assert conn.query_string =~ "created_at="
          send(test_pid, :pressure_read)
          Req.Test.json(conn, %{"data" => data})

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

  defp minutes_ago(minutes) do
    DateTime.utc_now() |> DateTime.add(-minutes, :minute) |> DateTime.to_iso8601()
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

  test "a fresh initiative pauses singles at the floor — the fresh message, one read, no operator question" do
    elicitation_capable()
    stub_api(@fresh_floor, minutes_ago(5))

    assert {:reply, response, @frame} =
             CreateTask.execute(%{initiative_id: 7, title: "Ninth, one at a time"}, @frame)

    {protocol, decoded} = decode(response)
    assert protocol["isError"] == true
    assert decoded["gate"] == "single_create_pause"
    assert decoded["message"] =~ "just created"
    assert decoded["message"] =~ "apply_operations"
    assert decoded["message"] =~ "#{@fresh_floor} recent adds"
    # Freshness rides the pressure GET — ONE read, not two.
    assert_received :pressure_read
    refute_received :pressure_read
    refute_received {:send_elicitation_request, _, _, _}
    refute_received :created
  end

  test "a fresh initiative under the floor still flows — the floor is exclusive" do
    elicitation_capable()
    stub_api(@fresh_floor - 1, minutes_ago(5))

    assert {:reply, response, @frame} =
             CreateTask.execute(%{initiative_id: 7, title: "Eighth"}, @frame)

    {protocol, _decoded} = decode(response)
    assert protocol["isError"] == false
    assert_received :created
  end

  test "an aged initiative keeps the normal threshold — floor-level pressure flows" do
    elicitation_capable()
    stub_api(@fresh_floor, minutes_ago(ImportPressure.window_minutes() + 5))

    assert {:reply, response, @frame} =
             CreateTask.execute(%{initiative_id: 7, title: "Settled"}, @frame)

    {protocol, _decoded} = decode(response)
    assert protocol["isError"] == false
    assert_received :created
  end

  test "an aged initiative past the normal threshold pauses with the batch-path message" do
    elicitation_capable()
    stub_api(@threshold, minutes_ago(ImportPressure.window_minutes() + 5))

    assert {:reply, response, @frame} =
             CreateTask.execute(%{initiative_id: 7, title: "One too many"}, @frame)

    {protocol, decoded} = decode(response)
    assert protocol["isError"] == true
    assert decoded["message"] =~ "#{@threshold} tasks have landed"
    refute decoded["message"] =~ "just created"
    refute_received :created
  end

  test "an operator-confirmed initiative flows freely past any pressure — fresh included" do
    elicitation_capable()
    start_counter()
    Counter.mark_confirmed({:existing, 7})
    stub_api(@threshold + 100, minutes_ago(1))

    assert {:reply, response, @frame} =
             CreateTask.execute(%{initiative_id: 7, title: "Sanctioned"}, @frame)

    {protocol, _decoded} = decode(response)
    assert protocol["isError"] == false
    assert_received :created
  end

  test "the pause holds for a client without elicitation too — the app carries the batch path's confirm (m03.04 item 30.4)" do
    fake_session(%{})
    stub_api(@threshold + 100)

    assert {:reply, response, @frame} =
             CreateTask.execute(%{initiative_id: 7, title: "Gated client"}, @frame)

    {protocol, decoded} = decode(response)
    assert protocol["isError"] == true
    assert decoded["gate"] == "single_create_pause"
    refute_received :created
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
