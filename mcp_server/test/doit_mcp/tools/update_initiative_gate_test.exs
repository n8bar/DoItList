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
  alias DoitMcp.{Elicitation, ImportGate}
  alias DoitMcp.Tools.{ApplyOperations, UpdateInitiative}
  alias DoitMcp.UpdateInitiativeGateTest.FakeSession

  @frame %{test: true}
  @threshold ImportGate.threshold()

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

  # GET returns the initiative's current knobs; POST applies and echoes the
  # decoded request body back to the test for the verbatim-write assertion.
  defp stub_knobs_get_and_apply(current_knobs) do
    parent = self()

    Req.Test.stub(DoitMcp.Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/v1/initiatives/3"} ->
          Req.Test.json(conn, %{"data" => %{"id" => 3, "ai_knobs" => current_knobs}})

        {"POST", "/api/v1/operations"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(parent, {:applied, Jason.decode!(body)})

          Req.Test.json(conn, %{
            "results" => [%{"index" => 0, "status" => "ok", "data" => %{"id" => 3}}]
          })
      end
    end)
  end

  # Fetch-only stub — an attempted apply has no matching clause and fails
  # loudly, proving nothing was recorded.
  defp stub_knobs_get_only(current_knobs) do
    Req.Test.stub(DoitMcp.Client, fn conn ->
      assert {conn.method, conn.request_path} == {"GET", "/api/v1/initiatives/3"}
      Req.Test.json(conn, %{"data" => %{"id" => 3, "ai_knobs" => current_knobs}})
    end)
  end

  defp import_batch(task_count) do
    for i <- 1..task_count do
      %{
        "op" => "add",
        "type" => "task",
        "lid" => "t#{i}",
        "data" => %{"initiative_id" => 3, "title" => "task #{i}"}
      }
    end
  end

  describe "first ai_knobs write gate (m03.04 fix 23)" do
    # The cross-checks against the import gate need it armed regardless of
    # the container's ambient environment.
    setup do
      Application.put_env(:doit_mcp, :import_gate_enabled, true)
      on_exit(fn -> Application.delete_env(:doit_mcp, :import_gate_enabled) end)
      :ok
    end

    test "the first write into empty knobs elicits the proposed text verbatim; approve applies" do
      elicitation_capable()
      stub_knobs_get_and_apply(nil)

      proposed = "grain: leaf-level checkboxes\nstyle: terse titles"
      params = %{initiative_id: 3, ai_knobs: proposed}
      task = Task.async(fn -> UpdateInitiative.execute(params, @frame) end)

      assert_receive {:send_elicitation_request, elicit_params, schema, timeout}, 2_000

      assert elicit_params["message"] =~ "Proposed knobs, verbatim:\n\n" <> proposed
      assert elicit_params["message"] =~ "decline records nothing"
      assert %{"type" => "object", "required" => ["approve"], "properties" => props} = schema
      assert props["approve"]["type"] == "boolean"
      assert timeout == to_timeout(minute: 5)

      Elicitation.deliver(%{"action" => "accept", "content" => %{"approve" => true}})

      assert {:reply, response, @frame} = Task.await(task, 5_000)
      assert_applied(response)

      # The applied op carries the knob text verbatim.
      assert_received {:applied, %{"operations" => [op]}}
      assert op["data"]["ai_knobs"] == proposed
    end

    test "an approved first write settles the import gate's knobs exemption" do
      elicitation_capable()
      stub_knobs_get_and_apply(nil)

      proposed = "grain: leaf-level checkboxes"
      params = %{initiative_id: 3, ai_knobs: proposed}
      task = Task.async(fn -> UpdateInitiative.execute(params, @frame) end)

      assert_receive {:send_elicitation_request, _, _, _}, 2_000
      Elicitation.deliver(%{"action" => "accept", "content" => %{"approve" => true}})
      assert {:reply, _response, @frame} = Task.await(task, 5_000)

      # The server now stores the knobs — a big import into this Initiative
      # rides the settled exemption instead of gating.
      stub_knobs_get_and_apply(proposed)

      assert {:reply, response, @frame} =
               ApplyOperations.execute(%{operations: import_batch(@threshold + 1)}, @frame)

      assert Response.to_protocol(response)["isError"] == false
      refute_received {:send_elicitation_request, _, _, _}
    end

    test "decline and approve=false record nothing — and the import gate stays armed" do
      elicitation_capable()
      stub_knobs_get_only(nil)

      params = %{initiative_id: 3, ai_knobs: "grain: fine"}

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
        assert text =~ "import gate stays armed"
        assert text =~ "Do not retry without the operator's request"
      end

      # Knobs are still empty server-side, so a big import still gates (held
      # for a readback; nothing applies — the stub would fail any POST).
      assert {:reply, gated, @frame} =
               ApplyOperations.execute(%{operations: import_batch(@threshold + 1)}, @frame)

      gated_protocol = Response.to_protocol(gated)
      assert gated_protocol["isError"] == true
      assert [%{"type" => "text", "text" => gated_text}] = gated_protocol["content"]
      assert gated_text =~ "readback"
    end

    test "a write to already-set knobs is ungated" do
      elicitation_capable()
      stub_knobs_get_and_apply("deploy_day: friday")

      params = %{initiative_id: 3, ai_knobs: "deploy_day: friday\ngrain: fine"}
      assert {:reply, response, @frame} = UpdateInitiative.execute(params, @frame)

      assert_applied(response)
      refute_received {:send_elicitation_request, _, _, _}
    end

    test "a first write without elicitation support refuses, naming the in-app control" do
      fake_session(%{"sampling" => %{}})
      stub_knobs_get_only(nil)

      params = %{initiative_id: 3, ai_knobs: "grain: fine"}
      assert {:reply, response, @frame} = UpdateInitiative.execute(params, @frame)

      protocol = Response.to_protocol(response)
      assert protocol["isError"] == true
      assert [%{"type" => "text", "text" => text}] = protocol["content"]
      assert text =~ "Initiative details pane"
      assert text =~ "AI knobs control"
      refute_received {:send_elicitation_request, _, _, _}
    end

    test "after an approved confirm, a failed-apply retry never re-elicits" do
      start_counter()
      elicitation_capable()
      stub_knobs_get_and_apply(nil)

      proposed = "grain: leaf-level checkboxes"
      params = %{initiative_id: 3, ai_knobs: proposed}
      task = Task.async(fn -> UpdateInitiative.execute(params, @frame) end)

      assert_receive {:send_elicitation_request, _, _, _}, 2_000
      Elicitation.deliver(%{"action" => "accept", "content" => %{"approve" => true}})
      assert {:reply, _response, @frame} = Task.await(task, 5_000)

      # The same write again (e.g. a retry after the apply failed) — knobs
      # are STILL empty server-side, but the session remembers the granted
      # confirm; no second ask.
      assert {:reply, response, @frame} = UpdateInitiative.execute(params, @frame)
      assert_applied(response)
      refute_received {:send_elicitation_request, _, _, _}
    end
  end
end
