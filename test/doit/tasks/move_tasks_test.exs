defmodule DoIt.Tasks.MoveTasksTest do
  @moduledoc """
  m04.02 item 2.1.1 — `Tasks.move_tasks/3`: an ordered list of Tasks lands
  under one parent as one contiguous block, in list order, with ONE
  `moved_many` event (undone as a whole) and ONE broadcast.
  """
  use DoIt.DataCase, async: true

  import Ecto.Query

  alias DoIt.{Accounts, Initiatives, Repo, Tasks}
  alias DoIt.Tasks.ActivityEvent

  defp user(name) do
    n = System.unique_integer([:positive])

    {:ok, u} =
      Accounts.register_user(%{
        "email" => "#{name}-#{n}@example.com",
        "username" => "#{name}-#{n}",
        "name" => name,
        "password" => "password123"
      })

    u
  end

  defp task(owner, init, parent, title, attrs \\ %{}) do
    parent_id = (parent && parent.id) || init.root_task_id

    {:ok, t} =
      Tasks.create_task(
        owner,
        Map.merge(
          %{"initiative_id" => init.id, "parent_id" => parent_id, "title" => title},
          attrs
        )
      )

    t
  end

  defp setup_init do
    owner = user("Owner")
    {:ok, init} = Initiatives.create_initiative(owner, %{"name" => "Init"})
    %{owner: owner, init: init}
  end

  defp get(id), do: Tasks.get_task!(id)
  defp child_ids(parent), do: Tasks.ordered_child_ids(parent.id)
  defp ids(tasks), do: Enum.map(tasks, & &1.id)

  defp moved_many_events(init) do
    Repo.all(
      from e in ActivityEvent,
        where: e.initiative_id == ^init.id and e.kind == "moved_many",
        order_by: [asc: e.id]
    )
  end

  # Two source parents with three children each, plus an empty destination.
  defp three_parents(owner, init) do
    a = task(owner, init, nil, "A")
    b = task(owner, init, nil, "B")
    c = task(owner, init, nil, "C")
    [a1, a2, a3] = for t <- ~w(a1 a2 a3), do: task(owner, init, a, t)
    [b1, b2, b3] = for t <- ~w(b1 b2 b3), do: task(owner, init, b, t)
    %{a: a, b: b, c: c, a1: a1, a2: a2, a3: a3, b1: b1, b2: b2, b3: b3}
  end

  describe "landing" do
    test "list order is kept and the block is contiguous at the top by default" do
      %{owner: owner, init: init} = setup_init()

      %{a: a, b: b, c: c, a1: a1, a2: a2, a3: a3, b1: b1, b2: b2, b3: b3} =
        three_parents(owner, init)

      c1 = task(owner, init, c, "c1")

      assert {:ok, moved} = Tasks.move_tasks([b2, a3, a1], owner, %{"parent_id" => c.id})

      assert ids(moved) == [b2.id, a3.id, a1.id]
      assert Enum.all?(moved, &(&1.parent_id == c.id))
      assert child_ids(c) == [b2.id, a3.id, a1.id, c1.id]
      assert child_ids(a) == [a2.id]
      assert child_ids(b) == [b1.id, b3.id]
    end

    test "a block whose sort order differs from creation order lands in list order (2.2)" do
      %{owner: owner, init: init} = setup_init()
      %{a: a, c: c, a1: a1, a2: a2, a3: a3} = three_parents(owner, init)
      c1 = task(owner, init, c, "c1")

      # A reads a3, a1, a2 — a3's slot no longer matches when it was created.
      {:ok, _} =
        Tasks.move_task(a3, owner, %{"parent_id" => a.id, "position" => 0, "reorder" => true})

      assert child_ids(a) == [a3.id, a1.id, a2.id]

      assert {:ok, moved} =
               Tasks.move_tasks([get(a3.id), get(a1.id), get(a2.id)], owner, %{
                 "parent_id" => c.id
               })

      assert ids(moved) == [a3.id, a1.id, a2.id]
      assert child_ids(c) == [a3.id, a1.id, a2.id, c1.id]
      assert child_ids(a) == []
    end

    test "the same block at an explicit position, and appended, keeps list order (2.2)" do
      %{owner: owner, init: init} = setup_init()
      %{a: a, c: c, a1: a1, a2: a2, a3: a3} = three_parents(owner, init)
      [c1, c2] = for t <- ~w(c1 c2), do: task(owner, init, c, t)

      {:ok, _} =
        Tasks.move_task(a3, owner, %{"parent_id" => a.id, "position" => 0, "reorder" => true})

      assert {:ok, _} =
               Tasks.move_tasks([get(a3.id), get(a1.id)], owner, %{
                 "parent_id" => c.id,
                 "position" => 1
               })

      assert child_ids(c) == [c1.id, a3.id, a1.id, c2.id]

      assert {:ok, _} =
               Tasks.move_tasks([get(a2.id), get(a3.id)], owner, %{
                 "parent_id" => c.id,
                 "position" => 99
               })

      assert child_ids(c) == [c1.id, a1.id, c2.id, a2.id, a3.id]
    end

    test "sources from several parents leave tidy siblings behind" do
      %{owner: owner, init: init} = setup_init()

      %{a: a, b: b, c: c, a2: a2, b1: b1, b3: b3, a1: a1, a3: a3, b2: b2} =
        three_parents(owner, init)

      assert {:ok, _} = Tasks.move_tasks([a2, b1, b3], owner, %{"parent_id" => c.id})

      assert child_ids(c) == [a2.id, b1.id, b3.id]
      assert child_ids(a) == [a1.id, a3.id]
      assert child_ids(b) == [b2.id]
    end

    test "an explicit position slots the block among existing children" do
      %{owner: owner, init: init} = setup_init()
      %{a: a, c: c, a1: a1, a2: a2} = three_parents(owner, init)
      [c1, c2, c3] = for t <- ~w(c1 c2 c3), do: task(owner, init, c, t)

      assert {:ok, _} =
               Tasks.move_tasks([a2, a1], owner, %{"parent_id" => c.id, "position" => 2})

      assert child_ids(c) == [c1.id, c2.id, a2.id, a1.id, c3.id]
      assert length(child_ids(a)) == 1
    end

    test "atom keys and a string position are accepted" do
      %{owner: owner, init: init} = setup_init()
      %{c: c, a1: a1} = three_parents(owner, init)
      c1 = task(owner, init, c, "c1")

      assert {:ok, _} = Tasks.move_tasks([a1], owner, %{parent_id: c.id, position: "1"})
      assert child_ids(c) == [c1.id, a1.id]
    end

    test "a task already under the destination is pulled into the block" do
      %{owner: owner, init: init} = setup_init()
      %{a: a, c: c, a1: a1, a2: a2} = three_parents(owner, init)
      [c1, c2, c3] = for t <- ~w(c1 c2 c3), do: task(owner, init, c, t)

      # c1 sits BEFORE the landing position, c3 after: both join the block in
      # list order and the remaining sibling keeps its relative place.
      assert {:ok, moved} =
               Tasks.move_tasks([c3, a1, c1, a2], owner, %{
                 "parent_id" => c.id,
                 "position" => 1
               })

      assert ids(moved) == [c3.id, a1.id, c1.id, a2.id]
      assert child_ids(c) == [c2.id, c3.id, a1.id, c1.id, a2.id]
      assert length(child_ids(a)) == 1
    end

    test "a position past the end appends" do
      %{owner: owner, init: init} = setup_init()
      %{c: c, a1: a1} = three_parents(owner, init)
      c1 = task(owner, init, c, "c1")

      assert {:ok, _} = Tasks.move_tasks([a1], owner, %{"parent_id" => c.id, "position" => 99})
      assert child_ids(c) == [c1.id, a1.id]
    end
  end

  describe "validation (nothing moves)" do
    test "a listed task that is an ancestor of the destination is a cycle" do
      %{owner: owner, init: init} = setup_init()
      %{a: a, b: b, a1: a1, b1: b1} = three_parents(owner, init)

      assert {:error, :cycle} = Tasks.move_tasks([b1, a], owner, %{"parent_id" => a1.id})

      assert get(b1.id).parent_id == b.id
      assert get(a.id).parent_id == init.root_task_id
      assert child_ids(a1) == []
      assert moved_many_events(init) == []
    end

    test "the destination itself in the list is a cycle" do
      %{owner: owner, init: init} = setup_init()
      %{a: a, b1: b1, b: b} = three_parents(owner, init)

      assert {:error, :cycle} = Tasks.move_tasks([b1, a], owner, %{"parent_id" => a.id})
      assert get(b1.id).parent_id == b.id
    end

    test "a destination in another Initiative is rejected" do
      %{owner: owner, init: init} = setup_init()
      {:ok, other} = Initiatives.create_initiative(owner, %{"name" => "Other"})
      %{a1: a1, a2: a2, a3: a3, a: a} = three_parents(owner, init)
      far = task(owner, other, nil, "far")

      assert {:error, :cross_initiative} =
               Tasks.move_tasks([a1, a2], owner, %{"parent_id" => far.id})

      assert child_ids(a) == [a1.id, a2.id, a3.id]
      assert child_ids(far) == []
    end

    test "a list spanning Initiatives is rejected" do
      %{owner: owner, init: init} = setup_init()
      {:ok, other} = Initiatives.create_initiative(owner, %{"name" => "Other"})
      %{c: c, a1: a1} = three_parents(owner, init)
      far = task(owner, other, nil, "far")

      assert {:error, :mixed_initiatives} =
               Tasks.move_tasks([a1, far], owner, %{"parent_id" => c.id})

      assert child_ids(c) == []
    end

    test "an empty list and duplicates are rejected" do
      %{owner: owner, init: init} = setup_init()
      %{c: c, a1: a1} = three_parents(owner, init)

      assert {:error, :empty} = Tasks.move_tasks([], owner, %{"parent_id" => c.id})
      assert {:error, :duplicate} = Tasks.move_tasks([a1, a1], owner, %{"parent_id" => c.id})
      assert child_ids(c) == []
    end

    test "a deleted destination is rejected" do
      %{owner: owner, init: init} = setup_init()
      %{c: c, a1: a1, a: a} = three_parents(owner, init)
      {:ok, _} = Tasks.delete_task(get(c.id), owner)

      assert {:error, :parent_deleted} = Tasks.move_tasks([a1], owner, %{"parent_id" => c.id})
      assert get(a1.id).parent_id == a.id
    end
  end

  describe "event and broadcast" do
    test "exactly one moved_many event, on the destination, with count and ordered ids" do
      %{owner: owner, init: init} = setup_init()
      %{c: c, a2: a2, b1: b1, a1: a1} = three_parents(owner, init)

      assert {:ok, _} =
               Tasks.move_tasks([a2, b1, a1], owner, %{"parent_id" => c.id, "position" => 0})

      assert [event] = moved_many_events(init)
      assert event.task_id == c.id
      assert event.user_id == owner.id
      assert event.data["to"] == c.id
      assert event.data["position"] == 0
      assert event.data["count"] == 3
      assert event.data["task_ids"] == [a2.id, b1.id, a1.id]

      # No per-task parent_changed / reordered events ride along.
      assert Repo.aggregate(
               from(e in ActivityEvent,
                 where: e.initiative_id == ^init.id and e.kind in ["parent_changed", "reordered"]
               ),
               :count
             ) == 0
    end

    test "the inverse payload records every prior slot in list order" do
      %{owner: owner, init: init} = setup_init()
      %{a: a, b: b, c: c, a3: a3, b1: b1} = three_parents(owner, init)

      assert {:ok, _} = Tasks.move_tasks([a3, b1], owner, %{"parent_id" => c.id})

      assert [event] = moved_many_events(init)

      assert event.inverse_payload["moves"] == [
               %{"task_id" => a3.id, "parent_id" => a.id, "position" => 2},
               %{"task_id" => b1.id, "parent_id" => b.id, "position" => 0}
             ]
    end

    test "exactly one broadcast, carrying the first moved task" do
      %{owner: owner, init: init} = setup_init()
      %{c: c, a2: a2, b1: b1} = three_parents(owner, init)

      :ok = Tasks.subscribe(init.id)
      assert {:ok, _} = Tasks.move_tasks([b1, a2], owner, %{"parent_id" => c.id})

      first = b1.id
      assert_receive {:task_moved, ^first}
      refute_receive {:task_moved, _}, 50
      # The delta envelope (m04.03 1.2) rides beside it, naming both moved tasks.
      assert_receive {:initiative_delta, %{upserts: upserts}}
      ids = Enum.map(upserts, & &1.id)
      assert b1.id in ids and a2.id in ids
      refute_receive _, 50
    end
  end

  describe "progress" do
    test "roll-up recomputes on the old and new chains" do
      %{owner: owner, init: init} = setup_init()
      a = task(owner, init, nil, "A")
      b = task(owner, init, nil, "B")
      a1 = task(owner, init, a, "a1")
      _a2 = task(owner, init, a, "a2")
      _b1 = task(owner, init, b, "b1")
      {:ok, _} = Tasks.update_task(get(a1.id), owner, %{"manual_progress" => 100})

      assert get(a.id).computed_progress == 50
      assert get(b.id).computed_progress == 0

      assert {:ok, _} = Tasks.move_tasks([get(a1.id)], owner, %{"parent_id" => b.id})

      assert get(a.id).computed_progress == 0
      assert get(b.id).computed_progress == 50
    end
  end

  describe "undo / redo" do
    test "undo puts every task back to its prior parent and index; redo re-applies" do
      %{owner: owner, init: init} = setup_init()

      %{a: a, b: b, c: c, a1: a1, a2: a2, a3: a3, b1: b1, b2: b2, b3: b3} =
        three_parents(owner, init)

      c1 = task(owner, init, c, "c1")
      c2 = task(owner, init, c, "c2")
      {:ok, _} = Tasks.update_task(get(c1.id), owner, %{"title" => "c1 renamed"})

      assert {:ok, _} =
               Tasks.move_tasks([b3, a2, c1, b1], owner, %{"parent_id" => c.id, "position" => 1})

      assert child_ids(c) == [c2.id, b3.id, a2.id, c1.id, b1.id]

      assert Tasks.undo_candidate(owner, init.id).kind == "moved_many"
      assert {:ok, "move 4 tasks"} = Tasks.undo(owner, init.id)

      assert child_ids(a) == [a1.id, a2.id, a3.id]
      assert child_ids(b) == [b1.id, b2.id, b3.id]
      assert child_ids(c) == [c1.id, c2.id]

      # The next undo is the action before the move.
      assert Tasks.undo_candidate(owner, init.id).kind == "title_changed"

      assert {:ok, "move 4 tasks"} = Tasks.redo(owner, init.id)
      assert child_ids(c) == [c2.id, b3.id, a2.id, c1.id, b1.id]
      assert child_ids(a) == [a1.id, a3.id]
      assert child_ids(b) == [b2.id]
    end

    test "undo restores progress on both chains" do
      %{owner: owner, init: init} = setup_init()
      a = task(owner, init, nil, "A")
      b = task(owner, init, nil, "B")
      a1 = task(owner, init, a, "a1")
      _a2 = task(owner, init, a, "a2")
      _b1 = task(owner, init, b, "b1")
      {:ok, _} = Tasks.update_task(get(a1.id), owner, %{"manual_progress" => 100})
      assert {:ok, _} = Tasks.move_tasks([get(a1.id)], owner, %{"parent_id" => b.id})

      assert {:ok, _} = Tasks.undo(owner, init.id)
      assert get(a.id).computed_progress == 50
      assert get(b.id).computed_progress == 0
    end

    test "undo skips a task that no longer exists and still restores the rest" do
      %{owner: owner, init: init} = setup_init()

      %{a: a, b: b, c: c, a1: a1, a2: a2, a3: a3, b1: b1, b2: b2, b3: b3} =
        three_parents(owner, init)

      assert {:ok, _} = Tasks.move_tasks([a2, b1], owner, %{"parent_id" => c.id})
      # Hard-remove b1 (its own events cascade away; the move's event lives on c).
      Repo.delete_all(from t in DoIt.Tasks.Task, where: t.id == ^b1.id)

      assert Tasks.undo_candidate(owner, init.id).kind == "moved_many"
      assert {:ok, _} = Tasks.undo(owner, init.id)
      assert child_ids(a) == [a1.id, a2.id, a3.id]
      assert child_ids(b) == [b2.id, b3.id]
      assert child_ids(c) == []
    end

    test "undo is a conflict when a prior parent is gone" do
      %{owner: owner, init: init} = setup_init()
      %{a: a, b: b, c: c, a2: a2, b1: b1} = three_parents(owner, init)

      assert {:ok, _} = Tasks.move_tasks([a2, b1], owner, %{"parent_id" => c.id})
      # Hard-remove A: its subtree and events cascade away.
      Repo.delete_all(from t in DoIt.Tasks.Task, where: t.id == ^a.id)

      assert {:error, {:conflict, "move 2 tasks"}} = Tasks.undo(owner, init.id)
      # Nothing was written: b1 is still under c, not back under b.
      assert get(b1.id).parent_id == c.id
      refute b1.id in child_ids(b)
    end

    test "describe_event copy" do
      assert Tasks.describe_event(%{kind: "moved_many", data: %{"count" => 3}}) ==
               "move 3 tasks"

      assert Tasks.describe_event(%{kind: "moved_many", data: %{"count" => 1}}) ==
               "move 1 task"
    end
  end
end
