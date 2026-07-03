defmodule DoIt.Tasks.RollupDebounceTest do
  @moduledoc """
  m03.02 items 4 / 5.4: the `:async` roll-up route. A write commits its OWN
  row's progress synchronously; ancestor chains defer to the per-Initiative
  `DoIt.Tasks.RollupDebounce`, which coalesces a window's dirty seeds into
  one recompute pass, broadcasts the changed ancestors post-commit, and
  stops. `async: false` + global config flips: the rest of the suite runs
  the `:inline` route (config/test.exs); only this file exercises the real
  GenServer.
  """
  use DoIt.DataCase, async: false

  alias DoIt.{Accounts, Initiatives, Tasks}
  alias DoIt.Tasks.RollupDebounce

  # Generous-but-fast windows: long enough that a burst of edits (a few ms
  # each) can't straddle a window boundary and flake, short enough that every
  # await below resolves in well under its assert_receive timeout.
  @debounce_ms 150
  @max_wait_ms 600

  setup do
    prev_route = Application.fetch_env(:doit, :rollup_recompute)
    prev_tuning = Application.fetch_env(:doit, RollupDebounce)

    Application.put_env(:doit, :rollup_recompute, :async)

    Application.put_env(:doit, RollupDebounce,
      debounce_ms: @debounce_ms,
      max_wait_ms: @max_wait_ms
    )

    on_exit(fn ->
      # Tear down any still-pending debouncer BEFORE DataCase's on_exit stops
      # the sandbox owner (on_exit is LIFO), so no pass fires against a dead
      # connection after the test ends.
      for {_, pid, _, _} <- DynamicSupervisor.which_children(RollupDebounce.supervisor()) do
        ref = Process.monitor(pid)
        DynamicSupervisor.terminate_child(RollupDebounce.supervisor(), pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          2_000 -> :ok
        end
      end

      restore_env(:rollup_recompute, prev_route)
      restore_env(RollupDebounce, prev_tuning)
    end)

    :ok
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:doit, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:doit, key)

  defp user do
    n = System.unique_integer([:positive])

    {:ok, u} =
      Accounts.register_user(%{
        "email" => "debounce-#{n}@example.com",
        "username" => "debounce-#{n}",
        "name" => "Debouncer",
        "password" => "password123"
      })

    u
  end

  defp init(owner) do
    {:ok, initiative} = Initiatives.create_initiative(owner, %{"name" => "Rollup debounce"})
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

  # Block until the Initiative has no debouncer left: no live process AND no
  # Registry entry. Loops because a dead pid's entry can outlive it for a beat
  # (Registry cleans up on its own DOWN, racing ours — the source of a real
  # 1-in-N flake here), and because a flush can chain into a fresh process
  # when an enqueue raced the stop. A DOWN of any reason counts (:noproc
  # covers the it-just-stopped race; the kill test asserts staleness itself).
  defp await_flush(initiative_id, attempts \\ 100)

  defp await_flush(initiative_id, 0),
    do: flunk("debouncer for initiative #{initiative_id} never went quiet")

  defp await_flush(initiative_id, attempts) do
    case RollupDebounce.whereis(initiative_id) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
        # Registry drops the entry when ITS monitor fires, racing ours, and a
        # dead pid's DOWN arrives instantly — without a pause this loop
        # busy-spins through its attempts faster than the cleanup can land.
        # There's no public hook to synchronize with, so: bounded 10ms poll.
        Process.sleep(10)
        await_flush(initiative_id, attempts - 1)
    end
  end

  # Every DB query fired by a process OTHER than the test process while `fun`
  # runs — i.e. the debouncer's pass (the only other live process under
  # async: false). Same `:telemetry` technique as rollup_batching_test.exs,
  # with the pid filter inverted.
  defp capture_pass_queries(fun) do
    handler_id = make_ref()
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:do_it, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() != test_pid do
          send(test_pid, {:pass_query, to_string(metadata.query)})
        end
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    drain_pass_queries()
  end

  defp drain_pass_queries do
    receive do
      {:pass_query, sql} -> [sql | drain_pass_queries()]
    after
      0 -> []
    end
  end

  defp pass_progress_writes(queries) do
    Enum.filter(queries, &(&1 =~ ~r/UPDATE "tasks".*"computed_progress" = CASE WHEN/s))
  end

  describe "coalescing" do
    test "N edits in one window run ONE recompute pass with one batched write" do
      owner = user()
      initiative = init(owner)
      parent = task(owner, initiative, nil, "P")
      leaves = for n <- 1..3, do: task(owner, initiative, parent, "L#{n}")

      # Let the creations' own window flush first, so the capture below sees
      # only the edits' pass.
      await_flush(initiative.id)

      queries =
        capture_pass_queries(fn ->
          for {leaf, value} <- Enum.zip(leaves, [30, 60, 90]) do
            {:ok, _} = Tasks.update_task(leaf, owner, %{"manual_progress" => value})
          end

          await_flush(initiative.id)
        end)

      # Three edits, one flush: exactly one batched ancestor write came from
      # the debouncer (each edit's own synchronous self-row write fires from
      # the test process and is filtered out).
      assert length(pass_progress_writes(queries)) == 1

      # avg(30, 60, 90) = 60 all the way up.
      assert get(parent.id).computed_progress == 60
      assert get(initiative.root_task_id).computed_progress == 60
    end
  end

  describe "lifecycle" do
    test "starts on demand and terminates normally after its flush" do
      owner = user()
      initiative = init(owner)
      parent = task(owner, initiative, nil, "P")
      leaf = task(owner, initiative, parent, "L")
      await_flush(initiative.id)

      assert RollupDebounce.whereis(initiative.id) == nil

      {:ok, _} = Tasks.update_task(leaf, owner, %{"manual_progress" => 40})

      pid = RollupDebounce.whereis(initiative.id)
      assert is_pid(pid)

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

      assert get(parent.id).computed_progress == 40
    end

    # capture_log: the killed process's checked-out connection logs a (benign)
    # Postgrex disconnect that would otherwise pollute the suite output.
    @tag capture_log: true
    test "a kill mid-window drops that pass; the next edit self-heals" do
      owner = user()
      initiative = init(owner)
      parent = task(owner, initiative, nil, "P")
      leaf = task(owner, initiative, parent, "L")

      {:ok, _} = Tasks.update_task(leaf, owner, %{"manual_progress" => 80})

      pid = RollupDebounce.whereis(initiative.id)
      assert is_pid(pid)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000

      # The window's whole seed set died with it: the leaf's own row was
      # written synchronously, but no ancestor pass ever ran.
      assert get(leaf.id).computed_progress == 80
      assert get(parent.id).computed_progress == 0

      # Any next edit near the chain re-seeds it; the pass recomputes from
      # CURRENT rows, healing the dropped window's ancestors too.
      {:ok, _} = Tasks.update_task(get(leaf.id), owner, %{"title" => "poke"})
      await_flush(initiative.id)

      assert get(parent.id).computed_progress == 80
      assert get(initiative.root_task_id).computed_progress == 80
    end
  end

  describe "bounded staleness" do
    test "ancestors lag only inside the window and are exact after the flush" do
      owner = user()
      initiative = init(owner)
      parent = task(owner, initiative, nil, "P")
      leaf = task(owner, initiative, parent, "L")
      await_flush(initiative.id)

      {:ok, updated} = Tasks.update_task(leaf, owner, %{"manual_progress" => 50})

      # Mid-window: the write's own row is already fresh; the ancestors still
      # carry their pre-edit values.
      assert updated.computed_progress == 50
      assert get(parent.id).computed_progress == 0

      await_flush(initiative.id)

      assert get(parent.id).computed_progress == 50
      assert get(initiative.root_task_id).computed_progress == 50
    end
  end

  describe "synchronous self value (item 4.2)" do
    test "async route: the returned struct carries the fresh value for progress and status" do
      owner = user()
      initiative = init(owner)
      parent = task(owner, initiative, nil, "P")
      leaf = task(owner, initiative, parent, "L")

      {:ok, updated} = Tasks.update_task(leaf, owner, %{"manual_progress" => 35})
      assert updated.computed_progress == 35

      {:ok, done} = Tasks.update_task(updated, owner, %{"status" => "done"})
      assert done.computed_progress == 100

      await_flush(initiative.id)
    end

    test "inline route: unchanged — fresh self value AND immediate ancestors, no debouncer" do
      Application.put_env(:doit, :rollup_recompute, :inline)

      owner = user()
      initiative = init(owner)
      parent = task(owner, initiative, nil, "P")
      leaf = task(owner, initiative, parent, "L")

      {:ok, updated} = Tasks.update_task(leaf, owner, %{"manual_progress" => 65})

      assert updated.computed_progress == 65
      assert get(parent.id).computed_progress == 65
      assert get(initiative.root_task_id).computed_progress == 65
      assert RollupDebounce.whereis(initiative.id) == nil
    end
  end

  describe "single_level mode" do
    test "the pass's sequential per-seed route converges shared ancestors" do
      owner = user()
      initiative = init(owner)

      {:ok, initiative} =
        Initiatives.update_initiative(
          Initiatives.get_initiative(initiative.id),
          %{"progress_calc" => "single_level"}
        )

      parent = task(owner, initiative, nil, "P")
      l1 = task(owner, initiative, parent, "L1")
      l2 = task(owner, initiative, parent, "L2")
      await_flush(initiative.id)

      {:ok, _} = Tasks.update_task(l1, owner, %{"manual_progress" => 40})
      {:ok, _} = Tasks.update_task(l2, owner, %{"manual_progress" => 80})
      await_flush(initiative.id)

      # P: avg of its DIRECT children (40, 80) = 60; the root's only child is P.
      assert get(parent.id).computed_progress == 60
      assert get(initiative.root_task_id).computed_progress == 60
    end
  end

  describe "post-commit broadcasts (item 4.5)" do
    test "the pass broadcasts {:task_updated, id} for each changed ancestor" do
      owner = user()
      initiative = init(owner)
      parent = task(owner, initiative, nil, "P")
      leaf = task(owner, initiative, parent, "L")
      await_flush(initiative.id)

      Tasks.subscribe(initiative.id)
      parent_id = parent.id
      root_id = initiative.root_task_id

      {:ok, _} = Tasks.update_task(leaf, owner, %{"manual_progress" => 90})

      # One broadcast per changed ancestor lands after the pass commits — a
      # viewer that full-loaded mid-window converges through its normal
      # {:task_updated} patch path.
      assert_receive {:task_updated, ^parent_id}, 5_000
      assert_receive {:task_updated, ^root_id}, 5_000
    end
  end

  describe "moves (item 4.3)" do
    test "a move enqueues the OLD parent's chain too — both sides converge" do
      owner = user()
      initiative = init(owner)
      a = task(owner, initiative, nil, "A")
      moving = task(owner, initiative, a, "Moving", %{"manual_progress" => 100})
      _stays = task(owner, initiative, a, "Stays")
      b = task(owner, initiative, nil, "B")
      _b_leaf = task(owner, initiative, b, "BLeaf")
      await_flush(initiative.id)

      # Before: a = avg(100, 0) = 50; b = 0.
      assert get(a.id).computed_progress == 50
      assert get(b.id).computed_progress == 0

      {:ok, _} = Tasks.move_task(get(moving.id), owner, %{"parent_id" => b.id})
      await_flush(initiative.id)

      # Old chain reconverged (a lost its only done leaf), new chain gained it.
      assert get(a.id).computed_progress == 0
      assert get(b.id).computed_progress == 50
      # Root sees leaves 0 (Stays), 0 (BLeaf), 100 (Moving) -> 33.
      assert get(initiative.root_task_id).computed_progress == 33
    end
  end
end
