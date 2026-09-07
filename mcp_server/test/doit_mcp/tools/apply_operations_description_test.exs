defmodule DoitMcp.Tools.ApplyOperationsDescriptionTest do
  use ExUnit.Case, async: true

  # m03.04 3.3.2: the tool words are the batch mechanics and nothing else —
  # wire format, `lid` rules, `done` on add, `%<id>` references, the
  # 150-operation cap, `idempotency_key`, and `expected_version`. The import
  # ceremony (3.1) left the tool, and its vocabulary must not creep back.
  describe "published tool description" do
    setup do
      # Collapsed whitespace so assertions survive the moduledoc's line wraps.
      description =
        DoitMcp.Tools.ApplyOperations.__description__()
        |> String.replace(~r/\s+/, " ")

      %{description: description}
    end

    test "states the cap and how to split past it", %{description: description} do
      assert description =~ "up to 150 ordered operations"
      assert description =~ "exceeds 150 operations"
      assert description =~ "split it into batches filled toward the cap"
      assert description =~ "Never loop per-operation tools"
    end

    test "states the wire format's fields", %{description: description} do
      assert description =~ ~s("op": "add" | "update" | "remove")
      assert description =~ ~s("type": "task" | "initiative")
      assert description =~ ~s("id": <real id)
      assert description =~ ~s("lid": <batch-local id)
      assert description =~ ~s("data": <fields documented by the corresponding domain tool>)
    end

    test "states the batch-local reference rules", %{description: description} do
      assert description =~ "Assign a unique `lid` to an add"
      assert description =~ "`parent_lid`, `initiative_lid`, `task_lid`, `source_lid`"
      assert description =~ "A `lid` always resolves to an earlier add of the required type"
      assert description =~ "Never reference a later add, reuse a `lid`, or carry one across"
      assert description =~ "always use the returned real ids"
    end

    test "keeps a lid out of `%<id>` text references", %{description: description} do
      assert description =~ "A `lid` never replaces the numeric id inside a `%<task_id>`"
      assert description =~ "add the tasks first and update the text after their real ids return"
    end

    test "puts `done` in the add that completes", %{description: description} do
      assert description =~ "Always set `done` in the task's add or update"
      assert description =~ "Never add a task and complete it with a second operation"
    end

    test "states the idempotency and conditional-write contracts", %{description: description} do
      assert description =~ "unique `idempotency_key`"
      assert description =~ "replays a committed response instead of applying it again"
      assert description =~ "Never reuse the key for a different batch"

      assert description =~ "latest read's `version` as `expected_version`"
      assert description =~ "rolls back the entire batch and returns the current record"
      assert description =~ "reconcile that record before retrying"
    end

    test "carries no import-ceremony vocabulary", %{description: description} do
      refute description =~ ~r/readback/i
      refute description =~ ~r/threshold/i
      refute description =~ ~r/approval/i
      refute description =~ ~r/declaration/i
      refute description =~ ~r/declared_/
      refute description =~ ~r/provenance/i
      refute description =~ ~r/operator/i
    end
  end
end
