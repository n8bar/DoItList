defmodule DoitMcp.Tools.ApplyOperationsMarkerTest do
  @moduledoc """
  The repo-marker suggestion on import-flavored applies (m03.04 2.1.4.2,
  rider predicate 2.8.7): a successful apply carrying import flavor — the
  gate fired, a bootstrap at the import floor, or floor-scale adds into an
  existing tree — ends with the guidance line plus the API-composed
  `repo_marker`; everyday and edit batches stay clean; one suggestion per
  Initiative per session (Counter pattern).
  """
  use ExUnit.Case, async: false

  alias Anubis.Server.Response
  alias DoitMcp.Tools.ApplyOperations

  @frame %{test: true}

  @marker "## Do It List\n" <>
            "Tasks: http://localhost:4000/initiatives/7 — work this tree via the " <>
            "doitlist MCP server, not a TODO.md or PLAN.md."

  @guidance "Always check the repo's agent-instruction file (`CLAUDE.md` or `AGENTS.md`) for a '## Do It List' marker. If absent, offer the operator this marker; never add it without approval:"

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

  # The first task arrives done, so the open-only guidance (its own test
  # file) stays out of these assertions.
  defp import_ops(task_count) do
    for i <- 1..task_count do
      data = %{"initiative_id" => 7, "title" => "task #{i}"}
      data = if i == 1, do: Map.put(data, "done", true), else: data
      %{"op" => "add", "type" => "task", "lid" => "t#{i}", "data" => data}
    end
  end

  defp text_blocks(response) do
    protocol = Response.to_protocol(response)
    assert protocol["isError"] == false
    for %{"type" => "text", "text" => text} <- protocol["content"], do: text
  end

  test "an import-flavored apply ends with the guidance line plus the composed marker" do
    stub_apply_and_list(self())

    assert {:reply, response, @frame} =
             ApplyOperations.execute(%{operations: import_ops(12)}, @frame)

    assert [_result, suggestion] = text_blocks(response)
    assert suggestion == @guidance <> "\n\n" <> @marker
  end

  test "a small everyday batch carries no import flavor — no read, no suggestion" do
    stub_apply_and_list(self())

    assert {:reply, response, @frame} =
             ApplyOperations.execute(%{operations: import_ops(3)}, @frame)

    assert [_result] = text_blocks(response)
    refute_received :marker_read
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
             ApplyOperations.execute(%{operations: import_ops(12)}, @frame)

    assert [_result, suggestion] = text_blocks(first)
    assert suggestion =~ @guidance
    assert_received :marker_read

    assert {:reply, second, @frame} =
             ApplyOperations.execute(%{operations: import_ops(12)}, @frame)

    assert [_result] = text_blocks(second)
    refute_received :marker_read
  end

  test "a sub-gate bootstrap import resolves the suggestion through the echoed real id" do
    stub_apply_and_list(self(), [
      %{"index" => 0, "lid" => "i", "status" => "ok", "data" => %{"id" => 7}}
    ])

    ops =
      [
        %{"op" => "add", "type" => "initiative", "lid" => "i", "data" => %{"name" => "Import"}}
      ] ++
        for i <- 1..12 do
          data = %{"initiative_lid" => "i", "title" => "task #{i}"}
          data = if i == 1, do: Map.put(data, "done", true), else: data
          %{"op" => "add", "type" => "task", "lid" => "t#{i}", "data" => data}
        end

    assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: ops}, @frame)

    assert [_result, suggestion] = text_blocks(response)
    assert suggestion == @guidance <> "\n\n" <> @marker
  end
end
