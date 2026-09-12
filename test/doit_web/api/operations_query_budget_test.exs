defmodule DoItWeb.Api.OperationsQueryBudgetTest do
  @moduledoc """
  Queries per op are BOUNDED (m03.04 2.7.5.4). A telemetry counter over
  fixture batches measures the marginal query cost of the two hot op shapes —
  a task add and a done-flip — by the diff method: per-op = (N-op batch −
  1-op batch) / (N − 1), so batch-constant work (the memo's first-op misses,
  the batch-end roll-up, begin/commit) cancels out.

  The 2.7.5 fixes this pins: the batch memo (Initiative row, member role,
  user preferences, resolved sort chain — loaded once per batch, not per op),
  the ancestor walks riding one `ancestors` CTE instead of a `Repo.get` per
  level, and the batch-end roll-up (the ancestor-chain reconcile fires once
  per touched branch per batch, never per op).

  Bounds sit just above the achieved cost (achieved + 2: add 9 → 11,
  flip 11 → 13) so a per-op regression fails loudly. The pre-fix baseline
  was add 29 / flip 40 (the 2.7.5.1 profile).

  `async: false`: the telemetry handler is process-filtered but the counts
  must not race another test's checkout on this connection.
  """
  use DoItWeb.ConnCase, async: false

  alias DoIt.{Accounts, Initiatives, Repo}
  alias DoIt.Tasks.Task
  alias DoItWeb.Api.Operations

  @add_per_op_budget 11
  @flip_per_op_budget 13

  @qlog :query_budget_log

  defp register(name) do
    {:ok, u} =
      Accounts.register_user(%{
        "email" => "#{name}-#{System.unique_integer([:positive])}@example.com",
        "username" => "#{name}-#{System.unique_integer([:positive])}",
        "name" => String.capitalize(name),
        "password" => "password123"
      })

    u
  end

  # A 5-deep ancestor chain plus sibling leaves at the bottom — deep enough
  # that a per-level walk or a per-op roll-up would show up in the counts.
  defp seed_chain(owner, ini, depth, leaves) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    base = %{
      status: "open",
      priority: "normal",
      manual_progress: 0,
      computed_progress: 0,
      initiative_id: ini.id,
      created_by_id: owner.id,
      updated_by_id: owner.id,
      inserted_at: now,
      updated_at: now
    }

    bottom =
      Enum.reduce(1..depth, ini.root_task_id, fn level, parent_id ->
        {_, [row]} =
          Repo.insert_all(
            Task,
            [Map.merge(base, %{title: "Chain #{level}", parent_id: parent_id, sort_order: 1})],
            returning: [:id]
          )

        row.id
      end)

    leaf_rows =
      for j <- 1..leaves do
        Map.merge(base, %{title: "Leaf #{j}", parent_id: bottom, sort_order: j})
      end

    {_, rows} = Repo.insert_all(Task, leaf_rows, returning: [:id])
    {bottom, Enum.map(rows, & &1.id)}
  end

  # Count [:*, :repo, :query] events fired by THIS process into an ETS log,
  # tagged with the nearest DoIt callers so the roll-up CTE can be counted by
  # its owning function. Both prefix spellings are attached; only the real
  # one ever fires.
  defp attach_qlog do
    :ets.new(@qlog, [:named_table, :public, :duplicate_bag])
    test_pid = self()

    for prefix <- [[:doit, :repo, :query], [:do_it, :repo, :query]] do
      :telemetry.attach(
        "query-budget-#{inspect(prefix)}",
        prefix,
        fn _event, _meas, _meta, _cfg ->
          if self() == test_pid do
            {:current_stacktrace, st} = Process.info(self(), :current_stacktrace)

            callers =
              st
              |> Enum.map(fn {m, f, a, _} -> "#{inspect(m)}.#{f}/#{a}" end)
              |> Enum.filter(&String.starts_with?(&1, "DoIt"))

            :ets.insert(@qlog, {:q, callers})
          end
        end,
        nil
      )
    end

    on_exit(fn ->
      for prefix <- [[:doit, :repo, :query], [:do_it, :repo, :query]] do
        :telemetry.detach("query-budget-#{inspect(prefix)}")
      end
    end)
  end

  defp reset_qlog, do: :ets.delete_all_objects(@qlog)

  defp qcount, do: :ets.info(@qlog, :size)

  # Queries attributable to the ancestor-chain roll-up reconcile — the work
  # 2.7.5.3 moves to batch end, once per touched branch.
  defp rollup_chain_fetches do
    :ets.tab2list(@qlog)
    |> Enum.count(fn {:q, callers} ->
      Enum.any?(callers, &String.contains?(&1, "fetch_ancestor_chain"))
    end)
  end

  defp add_op(parent_id, i),
    do: %{
      "op" => "add",
      "type" => "task",
      "lid" => "n#{i}",
      "data" => %{"parent_id" => parent_id, "title" => "Budgeted add #{i}"}
    }

  defp flip_op(id),
    do: %{"op" => "update", "type" => "task", "id" => id, "data" => %{"done" => true}}

  defp per_op(one_op_total, n_op_total, n), do: (n_op_total - one_op_total) / (n - 1)

  test "per-op query cost is bounded, and the roll-up reconcile fires once per touched branch" do
    owner = register("owner")

    {:ok, ini} =
      Initiatives.create_initiative(owner, %{"name" => "Budget Tree"}, agent_access: true)

    {bottom, leaf_ids} = seed_chain(owner, ini, 5, 20)

    attach_qlog()

    # --- adds: 1-op vs 6-op batch, all under one parent (one touched branch)
    {:ok, _} = Operations.apply_batch(owner, [add_op(bottom, 0)])

    reset_qlog()
    {:ok, _} = Operations.apply_batch(owner, [add_op(bottom, 1)])
    q_add_1 = qcount()

    assert rollup_chain_fetches() == 1,
           "expected ONE roll-up chain reconcile for a 1-op add batch (one touched branch), " <>
             "got #{rollup_chain_fetches()}"

    reset_qlog()
    {:ok, _} = Operations.apply_batch(owner, for(i <- 2..7, do: add_op(bottom, i)))
    q_add_6 = qcount()
    add_per_op = per_op(q_add_1, q_add_6, 6)

    # Once per TOUCHED BRANCH per batch — not once per op (2.7.5.3). All six
    # adds share one parent, so the 6-op batch still reconciles ONE chain.
    assert rollup_chain_fetches() == 1,
           "expected ONE roll-up chain reconcile for a 6-op single-branch add batch, " <>
             "got #{rollup_chain_fetches()} — the roll-up is firing per op again"

    assert add_per_op <= @add_per_op_budget,
           "task add costs #{add_per_op} queries/op — budget is #{@add_per_op_budget} " <>
             "(achieved 9 at 2.7.5; pre-fix baseline was 29)"

    # --- done-flips: 1-op vs 6-op batch on sibling leaves (one touched branch)
    [f1 | rest] = leaf_ids

    reset_qlog()
    {:ok, _} = Operations.apply_batch(owner, [flip_op(f1)])
    q_flip_1 = qcount()

    reset_qlog()
    {:ok, _} = Operations.apply_batch(owner, rest |> Enum.take(6) |> Enum.map(&flip_op/1))
    q_flip_6 = qcount()
    flip_per_op = per_op(q_flip_1, q_flip_6, 6)

    assert rollup_chain_fetches() == 1,
           "expected ONE roll-up chain reconcile for a 6-op single-branch flip batch, " <>
             "got #{rollup_chain_fetches()} — the roll-up is firing per op again"

    assert flip_per_op <= @flip_per_op_budget,
           "done-flip costs #{flip_per_op} queries/op — budget is #{@flip_per_op_budget} " <>
             "(achieved 11 at 2.7.5; pre-fix baseline was 40)"
  end
end
