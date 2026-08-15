defmodule DoitMcp.CreateTaskGateTest do
  # The single-create pause (m03.04 3.1 iteration 2): pressure is the
  # DATABASE's recent-creation window (DoitMcp.ImportPressure) — a drip
  # decays, a loop accumulates — and past the threshold the tool pauses
  # agent-facing, never asking the operator anything. The pause points at the
  # batch path, where an import-shaped batch's readback record (m03.04 item
  # 36) reopens the initiative, singles included.
  use ExUnit.Case, async: false

  alias Anubis.Server.Response
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

  # The window count comes from the API; POST creates; GET /tasks/42 resolves
  # a parent anchor. `pressure` seeds the initiative's recent-creation count;
  # :pressure_read lets tests pin the one-read doctrine.
  defp stub_api(pressure) do
    test_pid = self()

    Req.Test.stub(DoitMcp.Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/v1/initiatives/7/task_count"} ->
          assert conn.query_string =~ "created_at="
          send(test_pid, :pressure_read)
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
    stub_api(@threshold - 5)

    assert {:reply, response, @frame} =
             CreateTask.execute(%{initiative_id: 7, title: "One"}, @frame)

    {protocol, _decoded} = decode(response)
    assert protocol["isError"] == false
    assert_received :created
  end

  test "past the threshold the pause names the window and the batch path — no operator question" do
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
    # The no-stop recovery words (m03.04 2.29): the readback record, not
    # an operator confirm.
    assert decoded["message"] =~ "`readback`"
    assert decoded["message"] =~ "without a stop"
    assert_received :pressure_read
    refute_received :pressure_read
    refute_received :created
  end

  test "a parent-anchored create resolves its initiative and pauses past the threshold" do
    stub_api(@threshold + 3)

    assert {:reply, response, @frame} =
             CreateTask.execute(%{parent_id: 42, title: "Nested"}, @frame)

    {protocol, _decoded} = decode(response)
    assert protocol["isError"] == true
    refute_received :created
  end

  test "a just-created initiative pauses at the normal threshold — the fresh floor is retired (m03.04 2.29.2)" do
    # Floor-level pressure (the retired floor was 8) flows like any other.
    stub_api(8)

    assert {:reply, response, @frame} =
             CreateTask.execute(%{initiative_id: 7, title: "Ninth, one at a time"}, @frame)

    {protocol, _decoded} = decode(response)
    assert protocol["isError"] == false
    assert_received :created
  end

  test "an initiative with a recorded readback flows freely past any pressure" do
    start_counter()
    Counter.mark_confirmed({:existing, 7})
    stub_api(@threshold + 100)

    assert {:reply, response, @frame} =
             CreateTask.execute(%{initiative_id: 7, title: "Recorded"}, @frame)

    {protocol, _decoded} = decode(response)
    assert protocol["isError"] == false
    assert_received :created
  end

  test "the kill switch disarms the pause" do
    Application.put_env(:doit_mcp, :import_gate_enabled, false)
    stub_api(@threshold + 100)

    assert {:reply, response, @frame} =
             CreateTask.execute(%{initiative_id: 7, title: "Disarmed"}, @frame)

    {protocol, _decoded} = decode(response)
    assert protocol["isError"] == false
    assert_received :created
  end
end
