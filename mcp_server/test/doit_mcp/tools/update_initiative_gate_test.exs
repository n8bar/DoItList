defmodule DoitMcp.UpdateInitiativeGateTest.FakeSession do
  @moduledoc """
  Stands in for the Anubis session process in calc-gate tests: holds
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

defmodule DoitMcp.UpdateInitiativeGateTest do
  use ExUnit.Case, async: false

  alias Anubis.Server.Response
  alias DoitMcp.Elicitation
  alias DoitMcp.Tools.UpdateInitiative
  alias DoitMcp.UpdateInitiativeGateTest.FakeSession

  @frame %{test: true}

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

  defp start_counter do
    name = :"#{__MODULE__}.Counter"
    start_supervised!({DoitMcp.ImportGate.Counter, name: name})

    previous = Application.fetch_env(:doit_mcp, :import_gate_counter)
    Application.put_env(:doit_mcp, :import_gate_counter, name)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:doit_mcp, :import_gate_counter, value)
        :error -> Application.delete_env(:doit_mcp, :import_gate_counter)
      end
    end)
  end

  # GET returns the initiative's current calc; POST applies the update.
  defp stub_get_and_apply(current_calc) do
    Req.Test.stub(DoitMcp.Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/v1/initiatives/3"} ->
          Req.Test.json(conn, %{"data" => %{"id" => 3, "progress_calc" => current_calc}})

        {"POST", "/api/v1/operations"} ->
          Req.Test.json(conn, %{
            "results" => [%{"index" => 0, "status" => "ok", "data" => %{"id" => 3}}]
          })
      end
    end)
  end

  # Fetch-only stub — an attempted apply has no matching clause and fails loudly.
  defp stub_get_only(current_calc) do
    Req.Test.stub(DoitMcp.Client, fn conn ->
      assert {conn.method, conn.request_path} == {"GET", "/api/v1/initiatives/3"}
      Req.Test.json(conn, %{"data" => %{"id" => 3, "progress_calc" => current_calc}})
    end)
  end

  # Apply-only stub — an attempted fetch fails loudly, proving zero extra round trips.
  defp stub_apply_only do
    Req.Test.stub(DoitMcp.Client, fn conn ->
      assert {conn.method, conn.request_path} == {"POST", "/api/v1/operations"}

      Req.Test.json(conn, %{
        "results" => [%{"index" => 0, "status" => "ok", "data" => %{"id" => 3}}]
      })
    end)
  end

  defp assert_applied(response) do
    protocol = Response.to_protocol(response)
    assert protocol["isError"] == false
    assert [%{"type" => "text", "text" => text}] = protocol["content"]
    assert Jason.decode!(text) == %{"id" => 3}
  end

  test "an update without progress_calc takes zero extra round trips" do
    elicitation_capable()
    stub_apply_only()

    params = %{initiative_id: 3, name: "New name"}
    assert {:reply, response, @frame} = UpdateInitiative.execute(params, @frame)

    assert_applied(response)
    refute_received {:send_elicitation_request, _, _, _}
  end

  test "returning to leaf_average applies ungated, without even a fetch" do
    elicitation_capable()
    stub_apply_only()

    params = %{initiative_id: 3, progress_calc: "leaf_average"}
    assert {:reply, response, @frame} = UpdateInitiative.execute(params, @frame)

    assert_applied(response)
    refute_received {:send_elicitation_request, _, _, _}
  end

  test "re-sending the current non-default value applies ungated — no change happening" do
    elicitation_capable()
    stub_get_and_apply("single_level")

    params = %{initiative_id: 3, progress_calc: "single_level"}
    assert {:reply, response, @frame} = UpdateInitiative.execute(params, @frame)

    assert_applied(response)
    refute_received {:send_elicitation_request, _, _, _}
  end

  test "a change to non-default without elicitation support refuses, naming the in-app control" do
    fake_session(%{"sampling" => %{}})
    stub_get_only("leaf_average")

    params = %{initiative_id: 3, progress_calc: "single_level"}
    assert {:reply, response, @frame} = UpdateInitiative.execute(params, @frame)

    protocol = Response.to_protocol(response)
    assert protocol["isError"] == true
    assert [%{"type" => "text", "text" => text}] = protocol["content"]
    assert text =~ "Initiative details pane"
    assert text =~ "progress-calculation control"
    refute_received {:send_elicitation_request, _, _, _}
  end

  test "a change to non-default elicits; approve applies" do
    elicitation_capable()
    stub_get_and_apply("leaf_average")

    params = %{initiative_id: 3, progress_calc: "single_level"}
    task = Task.async(fn -> UpdateInitiative.execute(params, @frame) end)

    assert_receive {:send_elicitation_request, elicit_params, schema, timeout}, 2_000

    assert elicit_params["message"] =~ "from leaf_average to single_level"
    assert elicit_params["message"] =~ "Approve only if you asked for this"
    assert %{"type" => "object", "required" => ["approve"], "properties" => props} = schema
    assert props["approve"]["type"] == "boolean"
    assert timeout == to_timeout(minute: 5)

    Elicitation.deliver(%{"action" => "accept", "content" => %{"approve" => true}})

    assert {:reply, response, @frame} = Task.await(task, 5_000)
    assert_applied(response)
  end

  test "decline and approve=false both leave the calc unapplied" do
    elicitation_capable()
    stub_get_only("leaf_average")

    params = %{initiative_id: 3, progress_calc: "single_level"}

    for answer <- [
          %{"action" => "decline"},
          %{"action" => "accept", "content" => %{"approve" => false}}
        ] do
      task = Task.async(fn -> UpdateInitiative.execute(params, @frame) end)

      assert_receive {:send_elicitation_request, _, _, _}, 2_000
      Elicitation.deliver(answer)

      assert {:reply, response, @frame} = Task.await(task, 5_000)
      protocol = Response.to_protocol(response)
      assert protocol["isError"] == true
      assert [%{"type" => "text", "text" => text}] = protocol["content"]
      assert text =~ "did not approve"
      assert text =~ "Do not retry without the operator's request"
    end
  end

  test "after an approved confirm, retrying the same change does not re-elicit" do
    start_counter()
    elicitation_capable()
    stub_get_and_apply("leaf_average")

    params = %{initiative_id: 3, progress_calc: "single_level"}
    task = Task.async(fn -> UpdateInitiative.execute(params, @frame) end)

    assert_receive {:send_elicitation_request, _, _, _}, 2_000
    Elicitation.deliver(%{"action" => "accept", "content" => %{"approve" => true}})
    assert {:reply, _response, @frame} = Task.await(task, 5_000)

    # Same change again (e.g. a retry after a lost response) — the session
    # remembers the granted confirm; no second ask.
    assert {:reply, response, @frame} = UpdateInitiative.execute(params, @frame)
    assert_applied(response)
    refute_received {:send_elicitation_request, _, _, _}
  end
end
