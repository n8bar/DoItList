defmodule DoIt.Tasks.RollupBatchingTest do
  @moduledoc """
  m03.02 item 1: `reconcile_progress`'s ancestor recompute is scoped to the
  changed chain (not the whole Initiative) and writes it in one batched
  query; the completion cascade (`check_completed_ancestors` /
  `uncheck_done_ancestors`) does the same for status flips. `tasks_test.exs`
  and `progress_test.exs` already cover the roll-up MATH end to end — this
  file is about the query SHAPE: how few rows get touched, and how few
  queries it takes, via `:telemetry`'s `[:do_it, :repo, :query]` event.
  """
  use DoIt.DataCase, async: true

  alias DoIt.{Accounts, Initiatives, Tasks}

  defp user do
    n = System.unique_integer([:positive])

    {:ok, u} =
      Accounts.register_user(%{
        "email" => "roll-#{n}@example.com",
        "username" => "roll-#{n}",
        "name" => "Roller",
        "password" => "password123"
      })

    u
  end

  defp init(owner) do
    {:ok, initiative} = Initiatives.create_initiative(owner, %{"name" => "Rollup batching"})
    initiative
  end

  defp task(owner, initiative, parent, title, attrs \\ %{}) do
    parent_id = (parent && parent.id) || initiative.root_task_id

    {:ok, t} =
      Tasks.create_task(
        owner,
        Map.merge(
          %{"initiative_id" => initiative.id, "parent_id" => parent_id, "title" => title},
          attrs
        )
      )

    t
  end

  defp get(id), do: Tasks.get_task!(id)

  # Runs `fun`, capturing every DB query `fun` itself issues, as
  # `{sql, telemetry_result}` pairs in issue order. `:telemetry.attach` is
  # process-global — under `async: true`, other tests' concurrently-running
  # queries fire the same `[:do_it, :repo, :query]` event, so the handler
  # (which runs synchronously in whichever process fired the query) must
  # drop anything not from this test's own process before self-sending.
  defp capture_queries(fun) do
    handler_id = make_ref()
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:do_it, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == test_pid do
          send(test_pid, {:rollup_query, to_string(metadata.query), metadata.result})
        end
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    drain_queries()
  end

  defp drain_queries do
    receive do
      {:rollup_query, sql, result} -> [{sql, result} | drain_queries()]
    after
      0 -> []
    end
  end

  defp num_rows({:ok, %{num_rows: n}}), do: n
  defp num_rows(_), do: nil

  # The ancestor-chain CTE's final SELECT (`ancestor_chain_query/1`, reused
  # for the chain-scoped recompute) always projects from the "ancestors" CTE
  # alias — distinct from any other query touching the "tasks" table.
  defp ancestor_chain_fetches(queries) do
    Enum.filter(queries, fn {sql, _} -> sql =~ ~r/FROM "ancestors" AS a0/ end)
  end

  defp progress_batch_writes(queries) do
    Enum.filter(queries, fn {sql, _} ->
      sql =~ ~r/UPDATE "tasks".*"computed_progress" = CASE WHEN/s
    end)
  end

  defp status_batch_writes(queries) do
    Enum.filter(queries, fn {sql, _} ->
      sql =~ ~r/UPDATE "tasks" AS t0 SET "status"/ and sql =~ "= ANY("
    end)
  end

  describe "chain-scoped progress fetch (not the whole Initiative)" do
    test "editing a leaf only ever fetches its own ancestor chain" do
      owner = user()
      initiative = init(owner)

      # A short chain: root -> a -> b -> leaf.
      a = task(owner, initiative, nil, "A")
      b = task(owner, initiative, a, "B")
      leaf = task(owner, initiative, b, "Leaf")

      # An unrelated, much bigger sibling branch under root — if the fetch
      # were still whole-Initiative, its rows would show up in the count too.
      wide = task(owner, initiative, nil, "Wide")
      for n <- 1..40, do: task(owner, initiative, wide, "w#{n}")

      queries =
        capture_queries(fn -> Tasks.update_task(leaf, owner, %{"manual_progress" => 77}) end)

      chain_fetches = ancestor_chain_fetches(queries)

      assert chain_fetches != []

      # Every ancestors-CTE fetch this edit issues stays bounded to the
      # actual chain depth (leaf, b, a, root = 4) — nowhere near the ~44
      # rows a whole-Initiative fetch would have touched.
      for {_sql, result} <- chain_fetches do
        assert num_rows(result) <= 4
      end
    end
  end

  describe "batched progress write" do
    test "one query writes every changed ancestor in a straight chain" do
      owner = user()
      initiative = init(owner)

      # A single-child straight chain four levels deep: creating the leaf
      # with progress already set changes every ancestor's roll-up in one
      # shot (`create_task_body/2` only ever issues one chain recompute —
      # no old/new-parent split to muddy the count).
      p1 = task(owner, initiative, nil, "P1")
      p2 = task(owner, initiative, p1, "P2")
      p3 = task(owner, initiative, p2, "P3")

      queries =
        capture_queries(fn ->
          task(owner, initiative, p3, "Leaf", %{"manual_progress" => 100})
        end)

      batches = progress_batch_writes(queries)
      assert length(batches) == 1

      [{_sql, result}] = batches
      # The chain starts AT the newly created leaf (its own computed_progress
      # cache needs the same 0 -> 100 write) and climbs through p3, p2, p1,
      # to the Initiative's root task — 5 rows, one query.
      assert num_rows(result) == 5

      assert get(p1.id).computed_progress == 100
      assert get(p2.id).computed_progress == 100
      assert get(p3.id).computed_progress == 100
      assert get(initiative.root_task_id).computed_progress == 100
    end
  end

  describe "batched completion-cascade write" do
    test "marking a leaf done cascades multiple levels in one status query" do
      owner = user()
      initiative = init(owner)

      # Straight chain again — every level's only child completing lets the
      # cascade climb all the way to the root in one pass.
      p1 = task(owner, initiative, nil, "P1")
      p2 = task(owner, initiative, p1, "P2")
      p3 = task(owner, initiative, p2, "P3")
      leaf = task(owner, initiative, p3, "Leaf")

      queries = capture_queries(fn -> Tasks.toggle_complete(leaf, owner) end)
      batches = status_batch_writes(queries)

      assert length(batches) == 1
      [{_sql, result}] = batches
      # p1, p2, p3, and the root all auto-complete (leaf itself is written
      # separately, by its own individual flip_status/3 call).
      assert num_rows(result) == 4

      assert get(p1.id).status == "done"
      assert get(p2.id).status == "done"
      assert get(p3.id).status == "done"
      assert get(initiative.root_task_id).status == "done"
    end

    test "the cascade never touches an unrelated branch" do
      owner = user()
      initiative = init(owner)

      p1 = task(owner, initiative, nil, "P1")
      leaf = task(owner, initiative, p1, "Leaf")

      other = task(owner, initiative, nil, "Other")
      other_leaf = task(owner, initiative, other, "OtherLeaf")

      {:ok, _} = Tasks.toggle_complete(leaf, owner)

      assert get(p1.id).status == "done"
      # Unrelated branch is completely untouched by the cascade.
      assert get(other.id).status == "open"
      assert get(other_leaf.id).status == "open"
    end

    test "unchecking reverses multiple levels in one status query" do
      owner = user()
      initiative = init(owner)

      p1 = task(owner, initiative, nil, "P1")
      p2 = task(owner, initiative, p1, "P2")
      leaf = task(owner, initiative, p2, "Leaf")

      {:ok, _} = Tasks.toggle_complete(leaf, owner)
      assert get(p1.id).status == "done"

      queries = capture_queries(fn -> Tasks.toggle_complete(get(leaf.id), owner) end)

      status_batches =
        Enum.filter(queries, fn {sql, _} ->
          sql =~ ~r/UPDATE "tasks" AS t0 SET "status" = \$1, "manual_progress" = \$2/ and
            sql =~ "= ANY("
        end)

      assert length(status_batches) == 1
      [{_sql, result}] = status_batches
      # p1, p2, and the root revert to open in the one query.
      assert num_rows(result) == 3

      assert get(p1.id).status == "open"
      assert get(p2.id).status == "open"
      assert get(initiative.root_task_id).status == "open"
    end
  end

  describe "leaf_average vs single_level parity on a nontrivial tree" do
    # root
    #  └─ m
    #      ├─ x   (leaf, manual_progress 80)
    #      ├─ y
    #      │   ├─ y1 (leaf, manual_progress 40)
    #      │   └─ y2 (leaf, done -> 100)
    #      └─ z   (childless branch — the zero-child "treated as a leaf" edge
    #              case — manual_progress 10)
    defp build_nontrivial_tree(owner, initiative) do
      m = task(owner, initiative, nil, "M")
      x = task(owner, initiative, m, "X", %{"manual_progress" => 80})
      y = task(owner, initiative, m, "Y")
      y1 = task(owner, initiative, y, "Y1", %{"manual_progress" => 40})
      y2 = task(owner, initiative, y, "Y2")
      {:ok, y2} = Tasks.update_task(y2, owner, %{"status" => "done"})
      z = task(owner, initiative, m, "Z", %{"manual_progress" => 10})

      %{m: m, x: x, y: y, y1: y1, y2: y2, z: z}
    end

    test "leaf_average: matches hand-computed values, including the childless branch" do
      owner = user()
      initiative = init(owner)
      %{m: m, y: y} = build_nontrivial_tree(owner, initiative)

      # y: avg(y1=40, y2=100) = 70
      assert get(y.id).computed_progress == 70
      # m: avg over ALL leaves under it (x=80, y1=40, y2=100, z=10) = 230/4 = 57.5 -> 58
      assert get(m.id).computed_progress == 58
      # root has one child (m) and no leaves of its own — mirrors m.
      assert get(initiative.root_task_id).computed_progress == 58
    end

    test "single_level: matches hand-computed values, including the childless branch" do
      owner = user()
      initiative = init(owner)

      {:ok, initiative} =
        Initiatives.update_initiative(
          Initiatives.get_initiative(initiative.id),
          %{"progress_calc" => "single_level"}
        )

      %{m: m, y: y} = build_nontrivial_tree(owner, initiative)

      # y: avg(y1=40, y2=100) = 70 (same as leaf_average — y's children are leaves)
      assert get(y.id).computed_progress == 70
      # m: avg of its DIRECT children's rolled-up values (x=80, y=70, z=10) = 160/3 = 53.33 -> 53
      assert get(m.id).computed_progress == 53
      # root's one child is m.
      assert get(initiative.root_task_id).computed_progress == 53
    end

    test "switching progress_calc recomputes the whole stored tree under the new mode" do
      owner = user()
      initiative = init(owner)
      %{m: m, y: y} = build_nontrivial_tree(owner, initiative)

      # Built under leaf_average (see the hand math in the test above).
      assert get(m.id).computed_progress == 58

      {:ok, _} =
        Initiatives.update_initiative(
          Initiatives.get_initiative(initiative.id),
          %{"progress_calc" => "single_level"}
        )

      # Every stored value now matches the single_level math with no edit
      # needed — the switch itself recomputes the tree.
      assert get(y.id).computed_progress == 70
      assert get(m.id).computed_progress == 53
      assert get(initiative.root_task_id).computed_progress == 53
    end
  end

  describe "a branch reverting to childless mid-tree (scoped recompute, not just create-time)" do
    test "deleting a branch's last child reverts it to its own leaf value" do
      owner = user()
      initiative = init(owner)

      m = task(owner, initiative, nil, "M")
      # m starts with a manual_progress that only matters once it's childless.
      {:ok, m} = Tasks.update_task(m, owner, %{"manual_progress" => 25})
      only_child = task(owner, initiative, m, "OnlyChild", %{"manual_progress" => 90})

      # While it has a child, m's roll-up ignores its own manual_progress.
      assert get(m.id).computed_progress == 90

      {:ok, _} = Tasks.delete_task(get(only_child.id), owner)

      # Childless again: m is "treated as a leaf" — its OWN manual_progress
      # is what rolls up now, recomputed via the scoped ancestor chain
      # triggered by the delete (`recompute_ancestors/2`), not a whole-tree
      # walk.
      assert get(m.id).computed_progress == 25
      assert get(initiative.root_task_id).computed_progress == 25
    end
  end
end
