defmodule DoIt.UndoTest do
  @moduledoc """
  m02.06 items 2/3 + 11 — the inverse-action engine on one shared per-Initiative
  timeline. Each undoable kind round-trips (do → undo restores; redo re-applies);
  the next undo is the Initiative's newest action for anyone with rights; a
  viewer+ is walled at the first op outside their privileges; a dead target is
  skipped, not stuck.
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

  test "undo targets the Initiative's newest action, for anyone with rights (shared timeline)" do
    %{owner: owner, init: init} = setup_init()
    other = user("Other")
    {:ok, _} = Initiatives.add_member(init.id, other.id, "editor")

    t = task(owner, init, nil, "t")
    {:ok, _} = Tasks.update_task(get(t.id), owner, %{"title" => "owner-edit"})
    {:ok, _} = Tasks.update_task(get(t.id), other, %{"title" => "other-edit"})

    # The newest action (other's edit) is the next undo for BOTH members — not
    # each their own. Owner can reverse another member's most-recent edit.
    assert Tasks.undo_candidate(owner, init.id).user_id == other.id
    assert Tasks.undo_candidate(other, init.id).user_id == other.id

    assert {:ok, _} = Tasks.undo(owner, init.id)
    assert get(t.id).title == "owner-edit"
  end

  test "a viewer+ can undo within their privileges, then hits a wall (item 11.2)" do
    %{owner: owner, init: init} = setup_init()
    b = user("B")
    {:ok, _} = Initiatives.add_member(init.id, b.id, "viewer")
    led = task(owner, init, nil, "led")
    # B becomes a viewer+ — the direct assignee of `led` (viewer_plus on by default).
    {:ok, _} = Tasks.update_task(get(led.id), owner, %{"assignee_id" => to_string(b.id)})

    # B changes progress on the led task — within their rights, so undoable by B.
    {:ok, _} = Tasks.update_task(get(led.id), b, %{"manual_progress" => 50})
    assert Tasks.undo_candidate(b, init.id).kind == "progress_changed"

    # Owner renames the led task — a structural op B can't perform; now the top.
    {:ok, _} = Tasks.update_task(get(led.id), owner, %{"title" => "renamed"})
    assert Tasks.undo_candidate(b, init.id) == nil
    assert Tasks.undo_candidate(owner, init.id).kind == "title_changed"
  end

  test "a comment is undoable — undo removes it, redo restores it (item 14.5)" do
    %{owner: owner, init: init} = setup_init()
    t = task(owner, init, nil, "t")
    {:ok, _comment} = Tasks.add_comment(get(t.id), owner, "hi there")
    assert length(Tasks.list_comments(t.id)) == 1

    assert {:ok, _} = Tasks.undo(owner, init.id)
    assert Tasks.list_comments(t.id) == []

    assert {:ok, _} = Tasks.redo(owner, init.id)
    assert [%{body: "hi there"}] = Tasks.list_comments(t.id)
  end

  test "a plain viewer has nothing to undo" do
    %{owner: owner, init: init} = setup_init()
    v = user("V")
    {:ok, _} = Initiatives.add_member(init.id, v.id, "viewer")
    _t = task(owner, init, nil, "t")

    assert Tasks.undo_candidate(v, init.id) == nil
  end

  test "undo of a value edit broadcasts {:task_updated}, not a full reload (item 14.4)" do
    %{owner: owner, init: init} = setup_init()
    t = task(owner, init, nil, "v0")
    {:ok, _} = Tasks.update_task(get(t.id), owner, %{"title" => "v1"})

    Tasks.subscribe(init.id)
    {:ok, _} = Tasks.undo(owner, init.id)

    assert_receive {:task_updated, tid}
    assert tid == t.id
    refute_received {:task_created, _}
  end

  test "undo of a delete broadcasts a structural restore (item 14.4)" do
    %{owner: owner, init: init} = setup_init()
    parent = task(owner, init, nil, "P")
    child = task(owner, init, parent, "C")
    {:ok, _} = Tasks.delete_task(get(child.id), owner)

    Tasks.subscribe(init.id)
    {:ok, _} = Tasks.undo(owner, init.id)

    # Restoring a subtree changes tree shape — others reload, not patch.
    assert_receive {:task_created, _}
  end

  test "any member's fresh action invalidates the shared redo (item 11.3)" do
    %{owner: owner, init: init} = setup_init()
    other = user("Other")
    {:ok, _} = Initiatives.add_member(init.id, other.id, "editor")
    t = task(owner, init, nil, "v0")
    {:ok, _} = Tasks.update_task(get(t.id), owner, %{"title" => "v1"})
    {:ok, _} = Tasks.undo(owner, init.id)
    assert Tasks.redo_candidate(owner, init.id)

    # A different member's fresh edit clears the redo for everyone.
    {:ok, _} = Tasks.update_task(get(t.id), other, %{"title" => "v2"})
    assert Tasks.redo_candidate(owner, init.id) == nil
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
    refute Tasks.undo_candidate(owner, init.id) &&
             Tasks.undo_candidate(owner, init.id).kind == "parent_changed"
  end

  test "a fresh action invalidates the redo stack" do
    %{owner: owner, init: init} = setup_init()
    t = task(owner, init, nil, "v0")
    {:ok, _} = Tasks.update_task(get(t.id), owner, %{"title" => "v1"})
    {:ok, _} = Tasks.undo(owner, init.id)
    assert get(t.id).title == "v0"

    # A new edit after the undo — redo should now be gone.
    {:ok, _} = Tasks.update_task(get(t.id), owner, %{"title" => "v2"})
    assert Tasks.redo_candidate(owner, init.id) == nil
    assert {:error, :nothing_to_redo} = Tasks.redo(owner, init.id)
  end
end
