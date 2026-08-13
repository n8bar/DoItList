defmodule DoIt.ConditionalWritesTest do
  @moduledoc """
  Conditional writes (m03.04 item 32) at the context level: the `version`
  revision counter bumps on every intent-bearing write, stays still on derived
  roll-up recomputes, and `check_version/2` passes a matching token, conflicts
  a stale one with the current record, and waves a `nil` token through.
  """
  use DoIt.DataCase, async: true

  alias DoIt.{Accounts, Initiatives, Repo, Tasks}
  alias DoIt.Tasks.Task

  defp setup_user_and_initiative(_) do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "owner-#{System.unique_integer([:positive])}@example.com",
        "username" => "owner-#{System.unique_integer([:positive])}",
        "name" => "Owner",
        "password" => "password123"
      })

    {:ok, initiative} = Initiatives.create_initiative(user, %{"name" => "Versioned"})

    %{user: user, initiative: initiative}
  end

  setup :setup_user_and_initiative

  defp new_task(user, initiative, attrs) do
    attrs =
      attrs
      |> Map.put("initiative_id", initiative.id)
      |> Map.put_new("parent_id", initiative.root_task_id)

    {:ok, task} = Tasks.create_task(user, attrs)
    task
  end

  defp db_version(%Task{id: id}),
    do: Repo.one!(from t in Task, where: t.id == ^id, select: t.version)

  defp db_version(%Initiatives.Initiative{id: id} = _ini) do
    Repo.one!(from i in Initiatives.Initiative, where: i.id == ^id, select: i.version)
  end

  describe "task version bumps" do
    test "a fresh task starts at version 1 and a field update bumps it", %{
      user: user,
      initiative: initiative
    } do
      task = new_task(user, initiative, %{"title" => "A"})
      assert task.version == 1

      {:ok, updated} = Tasks.update_task(task, user, %{"title" => "A sharpened"})
      assert updated.version == 2
      assert db_version(task) == 2
    end

    test "a no-change update does not bump", %{user: user, initiative: initiative} do
      task = new_task(user, initiative, %{"title" => "A"})

      {:ok, updated} = Tasks.update_task(task, user, %{"title" => "A"})
      assert updated.version == 1
      assert db_version(task) == 1
    end

    test "a move bumps the moved task, not the renumbered sibling", %{
      user: user,
      initiative: initiative
    } do
      parent = new_task(user, initiative, %{"title" => "P"})
      a = new_task(user, initiative, %{"title" => "A", "parent_id" => parent.id})
      b = new_task(user, initiative, %{"title" => "B", "parent_id" => parent.id})

      {:ok, moved} = Tasks.move_task(b, user, %{"parent_id" => parent.id, "position" => 0})

      assert moved.version == 2
      # The sibling's sort_order renumber is mechanical bookkeeping — silent.
      assert db_version(a) == 1
    end

    test "cascade completion bumps the acted task, descendants, and auto-checked ancestors",
         %{user: user, initiative: initiative} do
      parent = new_task(user, initiative, %{"title" => "P"})
      branch = new_task(user, initiative, %{"title" => "B", "parent_id" => parent.id})
      leaf = new_task(user, initiative, %{"title" => "L", "parent_id" => branch.id})

      {:ok, _} = Tasks.cascade_complete(branch, user)

      # branch + leaf flip explicitly; parent auto-checks via the ancestor
      # cascade (its only child is now done) — all newer intent, all bump.
      assert db_version(branch) == 2
      assert db_version(leaf) == 2
      assert db_version(parent) == 2
    end

    test "EXEMPT: a leaf progress edit never bumps the parent the roll-up recomputes",
         %{user: user, initiative: initiative} do
      parent = new_task(user, initiative, %{"title" => "P"})
      leaf = new_task(user, initiative, %{"title" => "L", "parent_id" => parent.id})

      {:ok, updated_leaf} = Tasks.update_task(leaf, user, %{"manual_progress" => 50})

      # The parent's computed_progress moved with the roll-up...
      assert Repo.get!(Task, parent.id).computed_progress == 50
      # ...but the leaf carries the intent; the parent's version is untouched.
      assert updated_leaf.version == 2
      assert db_version(parent) == 1
    end

    test "delete and restore each bump the subtree", %{user: user, initiative: initiative} do
      parent = new_task(user, initiative, %{"title" => "P"})
      child = new_task(user, initiative, %{"title" => "C", "parent_id" => parent.id})

      {:ok, _} = Tasks.delete_task(parent, user)
      assert db_version(parent) == 2
      assert db_version(child) == 2

      {:ok, _} = Tasks.restore_tasks([parent.id, child.id], parent.parent_id, initiative.id)
      assert db_version(parent) == 3
      assert db_version(child) == 3
    end
  end

  describe "Tasks.check_version/2" do
    test "matching token passes, stale token conflicts with the current record, nil passes",
         %{user: user, initiative: initiative} do
      task = new_task(user, initiative, %{"title" => "A"})
      {:ok, updated} = Tasks.update_task(task, user, %{"title" => "A2"})

      {:ok, results} =
        Repo.transaction(fn ->
          {
            Tasks.check_version(updated, updated.version),
            Tasks.check_version(updated, updated.version - 1),
            Tasks.check_version(updated, nil)
          }
        end)

      assert {:ok, {:error, {:version_conflict, current}}, :ok} = results
      assert current.id == task.id
      assert current.version == updated.version
      assert current.title == "A2"
    end
  end

  describe "initiative version bumps" do
    test "a content update bumps; a no-change update does not", %{initiative: initiative} do
      assert initiative.version == 1

      {:ok, updated} = Initiatives.update_initiative(initiative, %{"name" => "Renamed"})
      assert updated.version == 2

      {:ok, same} = Initiatives.update_initiative(updated, %{"name" => "Renamed"})
      assert same.version == 2
    end

    test "a subtitle write bumps the Initiative (its payload content changed)", %{
      initiative: initiative
    } do
      {:ok, _root} = Initiatives.update_subtitle(initiative, "ship the dashboard")
      assert db_version(initiative) == 2

      # Unchanged subtitle: no write, no bump.
      {:ok, _root} = Initiatives.update_subtitle(initiative, "ship the dashboard")
      assert db_version(initiative) == 2
    end

    test "trash and restore bump", %{initiative: initiative} do
      {:ok, trashed} = Initiatives.trash_initiative(initiative)
      assert trashed.version == 2

      {:ok, restored} = Initiatives.restore_initiative(trashed)
      assert restored.version == 3
    end
  end

  describe "Initiatives.check_version/2" do
    test "matching passes, stale conflicts with the current record, nil passes", %{
      initiative: initiative
    } do
      {:ok, updated} = Initiatives.update_initiative(initiative, %{"name" => "Renamed"})

      {:ok, results} =
        Repo.transaction(fn ->
          {
            Initiatives.check_version(updated, updated.version),
            Initiatives.check_version(updated, 1),
            Initiatives.check_version(updated, nil)
          }
        end)

      assert {:ok, {:error, {:version_conflict, current}}, :ok} = results
      assert current.id == initiative.id
      assert current.version == updated.version
      assert current.name == "Renamed"
    end
  end
end
