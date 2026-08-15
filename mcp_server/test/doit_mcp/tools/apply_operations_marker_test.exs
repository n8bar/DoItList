defmodule DoitMcp.Tools.ApplyOperationsMarkerTest do
  @moduledoc """
  The repo-marker suggestion on import-shaped applies (m03.04 2.4.2): a
  successful apply whose task-adds resolve to a target Initiative — the
  import gate's own batch classification, reused — ends with the guidance
  line plus the API-composed `repo_marker`; edit batches stay clean; one
  suggestion per Initiative per session (Counter pattern).
  """
  use ExUnit.Case, async: false

  alias Anubis.Server.Response
  alias DoitMcp.Tools.ApplyOperations

  @frame %{test: true}

  @marker "## Do It List\n" <>
            "Tasks: http://localhost:4000/initiatives/7 — work this tree via the " <>
            "doitlist MCP server, not a TODO.md or PLAN.md."

  @guidance "If the repo's agent-instruction file (CLAUDE.md, AGENTS.md) has no " <>
              "'## Do It List' marker, offer the operator to add it:"

  # The suggestion is guidance, not a guardrail — it rides the gate's batch
  # classification but not its kill switch. Pin the gate off so these tests
  # isolate the suggestion (no pressure reads, no holds).
  setup do
    Application.put_env(:doit_mcp, :import_gate_enabled, false)
    on_exit(fn -> Application.delete_env(:doit_mcp, :import_gate_enabled) end)
    :ok
  end

  # The once-per-session tests need the confirm memory; everything else runs
  # counter-less (Counter degrades to never-suggested).
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

  # POST applies; GET /api/v1/initiatives serves the marker-bearing summary
  # and reports each read to the test process, so read-count is assertable.
  defp stub_apply_and_list(reply_to, results \\ []) do
    Req.Test.stub(DoitMcp.Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/api/v1/operations"} ->
          Req.Test.json(conn, %{"results" => results})

        {"GET", "/api/v1/initiatives"} ->
          send(reply_to, :marker_read)

          Req.Test.json(conn, %{
            "data" => [%{"id" => 7, "name" => "Q3 Launch", "repo_marker" => @marker}]
          })
      end
    end)
  end

  defp import_ops(task_count) do
    for i <- 1..task_count do
      %{
        "op" => "add",
        "type" => "task",
        "lid" => "t#{i}",
        "data" => %{"initiative_id" => 7, "title" => "task #{i}"}
      }
    end
  end

  defp text_blocks(response) do
    protocol = Response.to_protocol(response)
    assert protocol["isError"] == false
    for %{"type" => "text", "text" => text} <- protocol["content"], do: text
  end

  test "an import-shaped apply ends with the guidance line plus the composed marker" do
    stub_apply_and_list(self())

    assert {:reply, response, @frame} =
             ApplyOperations.execute(%{operations: import_ops(3)}, @frame)

    assert [_result, suggestion] = text_blocks(response)
    assert suggestion == @guidance <> "\n\n" <> @marker
  end

  test "an edit-shaped batch (no task-adds) never reads or suggests" do
    stub_apply_and_list(self())

    ops = [
      %{"op" => "update", "type" => "task", "id" => 5, "data" => %{"done" => true}},
      %{"op" => "update", "type" => "task", "id" => 6, "data" => %{"manual_progress" => 50}}
    ]

    assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: ops}, @frame)

    assert [_result] = text_blocks(response)
    refute_received :marker_read
  end

  test "a second import into the same Initiative this session carries no suggestion" do
    start_counter()
    stub_apply_and_list(self())

    assert {:reply, first, @frame} =
             ApplyOperations.execute(%{operations: import_ops(3)}, @frame)

    assert [_result, suggestion] = text_blocks(first)
    assert suggestion =~ @guidance
    assert_received :marker_read

    assert {:reply, second, @frame} =
             ApplyOperations.execute(%{operations: import_ops(2)}, @frame)

    assert [_result] = text_blocks(second)
    refute_received :marker_read
  end

  test "a bootstrap import resolves the suggestion through the echoed real id" do
    stub_apply_and_list(self(), [
      %{"index" => 0, "lid" => "i", "status" => "ok", "data" => %{"id" => 7}}
    ])

    ops = [
      %{"op" => "add", "type" => "initiative", "lid" => "i", "data" => %{"name" => "Import"}},
      %{
        "op" => "add",
        "type" => "task",
        "lid" => "t1",
        "data" => %{"initiative_lid" => "i", "title" => "first task"}
      }
    ]

    assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: ops}, @frame)

    assert [_result, suggestion] = text_blocks(response)
    assert suggestion == @guidance <> "\n\n" <> @marker
  end
end
