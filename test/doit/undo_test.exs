defmodule DoIt.UndoTest do
  @moduledoc """
  m02.06 items 2/3 — the inverse-action engine + per-(user, Initiative) stack.
  Each undoable kind round-trips (do → undo restores; redo re-applies); a
  user's undo only touches their own events; a dead target is skipped, not stuck.
  """
  use DoIt.DataCase, async: true

  alias DoIt.{Accounts, Initiatives, Tasks}

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
        Map.merge(%{"initiative_id" => init.id, "parent_id" => parent_id, "title" => title}, attrs)
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

  test "title change round-trips" do
    %{owner: owner, init: init} = setup_init()
    t = task(owner, init, nil, "before")
    {:ok, _} = Tasks.update_task(get(t.id), owner, %{"title" => "after"})

    assert get(t.id).title == "after"
    assert {:ok, _} = Tasks.undo(owner, init.id)
    assert get(t.id).title == "before"
    assert {:ok, _} = Tasks.redo(owner, init.id)
    assert get(t.id).title == "after"
  end

  test "progress change round-trips and rolls up" do
    %{owner: owner, init: init} = setup_init()
    leaf = task(owner, init, nil, "leaf")
    {:ok, _} = Tasks.update_task(get(leaf.id), owner, %{"manual_progress" => 80})

    assert get(leaf.id).manual_progress == 80
    assert {:ok, _} = Tasks.undo(owner, init.id)
    assert get(leaf.id).manual_progress == 0
    assert {:ok, _} = Tasks.redo(owner, init.id)
    assert get(leaf.id).manual_progress == 80
  end

  test "delete round-trips (restore the subtree, then re-delete)" do
    %{owner: owner, init: init} = setup_init()
    parent = task(owner, init, nil, "P")
    child = task(owner, init, parent, "C")

    {:ok, _} = Tasks.delete_task(get(child.id), owner)
    assert get(child.id).deleted_at

    assert {:ok, "delete \"C\""} = Tasks.undo(owner, init.id)
    assert get(child.id).deleted_at == nil

    assert {:ok, _} = Tasks.redo(owner, init.id)
    assert get(child.id).deleted_at
  end

  test "create round-trips (undo soft-deletes the new task)" do
    %{owner: owner, init: init} = setup_init()
    t = task(owner, init, nil, "fresh")

    assert {:ok, "create \"fresh\""} = Tasks.undo(owner, init.id)
    assert get(t.id).deleted_at

    assert {:ok, _} = Tasks.redo(owner, init.id)
    assert get(t.id).deleted_at == nil
  end

  test "move round-trips (back to the old parent, then forward again)" do
    %{owner: owner, init: init} = setup_init()
    a = task(owner, init, nil, "A")
    b = task(owner, init, nil, "B")
    moved = task(owner, init, a, "M")

    {:ok, _} = Tasks.move_task(get(moved.id), owner, %{"parent_id" => b.id})
    assert get(moved.id).parent_id == b.id

    assert {:ok, "move"} = Tasks.undo(owner, init.id)
    assert get(moved.id).parent_id == a.id

    assert {:ok, _} = Tasks.redo(owner, init.id)
    assert get(moved.id).parent_id == b.id
  end

  test "reorder round-trips to the original sibling order" do
    %{owner: owner, init: init} = setup_init()
    parent = task(owner, init, nil, "P")
    x = task(owner, init, parent, "x")
    y = task(owner, init, parent, "y")
    z = task(owner, init, parent, "z")

    assert child_ids(parent) == [x.id, y.id, z.id]

    # Move z to the front.
    {:ok, _} = Tasks.move_task(get(z.id), owner, %{"parent_id" => parent.id, "position" => 0})
    assert child_ids(parent) == [z.id, x.id, y.id]

    assert {:ok, _} = Tasks.undo(owner, init.id)
    assert child_ids(parent) == [x.id, y.id, z.id]

    assert {:ok, _} = Tasks.redo(owner, init.id)
    assert child_ids(parent) == [z.id, x.id, y.id]
  end

  test "a user's undo only pops their own events" do
    %{owner: owner, init: init} = setup_init()
    other = user("Other")
    {:ok, _} = Initiatives.add_member(init.id, other.id, "editor")

    t = task(owner, init, nil, "t")
    {:ok, _} = Tasks.update_task(get(t.id), owner, %{"title" => "owner-edit"})
    {:ok, _} = Tasks.update_task(get(t.id), other, %{"title" => "other-edit"})

    # Owner undo skips the other user's edit and finds their own (the create /
    # title). The other user's most recent edit is theirs to undo.
    assert Tasks.undo_candidate(owner.id, init.id).user_id == owner.id
    assert Tasks.undo_candidate(other.id, init.id).user_id == other.id
  end

  test "undoing into a vanished target is a skipped conflict, not a stall" do
    %{owner: owner, init: init} = setup_init()
    import Ecto.Query
    a = task(owner, init, nil, "A")
    b = task(owner, init, nil, "B")
    moved = task(owner, init, a, "M")

    # Move M out of A so deleting A won't touch M, then soft-delete A directly
    # (no event), leaving the move as the newest undoable.
    {:ok, _} = Tasks.move_task(get(moved.id), owner, %{"parent_id" => b.id})
    {1, _} = DoIt.Repo.update_all(from(t in DoIt.Tasks.Task, where: t.id == ^a.id), set: [deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)])

    # Undo would move M back under A — but A is gone. Surface a conflict and
    # step past the dead entry instead of stalling.
    assert {:error, {:conflict, "move"}} = Tasks.undo(owner, init.id)
    refute Tasks.undo_candidate(owner.id, init.id) &&
             Tasks.undo_candidate(owner.id, init.id).kind == "parent_changed"
  end

  test "a fresh action invalidates the redo stack" do
    %{owner: owner, init: init} = setup_init()
    t = task(owner, init, nil, "v0")
    {:ok, _} = Tasks.update_task(get(t.id), owner, %{"title" => "v1"})
    {:ok, _} = Tasks.undo(owner, init.id)
    assert get(t.id).title == "v0"

    # A new edit after the undo — redo should now be gone.
    {:ok, _} = Tasks.update_task(get(t.id), owner, %{"title" => "v2"})
    assert Tasks.redo_candidate(owner.id, init.id) == nil
    assert {:error, :nothing_to_redo} = Tasks.redo(owner, init.id)
  end
end
