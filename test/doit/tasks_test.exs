defmodule DoIt.TasksTest do
  @moduledoc """
  Integration tests for the Tasks context: progress roll-up actually persists
  to the database when a leaf task changes, and activity events are recorded.
  """
  use DoIt.DataCase, async: true

  alias DoIt.{Accounts, Initiatives, Tasks}

  defp setup_user_and_initiative(_) do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "owner-#{System.unique_integer([:positive])}@example.com",
        "name" => "Owner",
        "password" => "password123"
      })

    {:ok, initiative} = Initiatives.create_initiative(user, %{"name" => "Test initiative"})

    %{user: user, initiative: initiative}
  end

  setup :setup_user_and_initiative

  test "creating a leaf records its manual progress as 0", %{user: user, initiative: initiative} do
    {:ok, task} =
      Tasks.create_task(user, %{
        "initiative_id" => initiative.id,
        "title" => "Solo"
      })

    assert task.manual_progress == 0
    assert task.computed_progress == 0
  end

  test "updating a leaf rolls progress up to root", %{user: user, initiative: initiative} do
    {:ok, root} = Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "Root"})

    {:ok, _a} =
      Tasks.create_task(user, %{
        "initiative_id" => initiative.id,
        "parent_id" => root.id,
        "title" => "A"
      })

    {:ok, b} =
      Tasks.create_task(user, %{
        "initiative_id" => initiative.id,
        "parent_id" => root.id,
        "title" => "B"
      })

    # Set leaf B to 100; root should average to 50.
    {:ok, _b2} = Tasks.update_task(b, user, %{"manual_progress" => 100})

    refreshed_root = Tasks.get_task!(root.id)
    assert refreshed_root.computed_progress == 50
  end

  test "weighted children roll up correctly to grandparent", %{user: user, initiative: initiative} do
    {:ok, root} = Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "Root"})

    {:ok, mid} =
      Tasks.create_task(user, %{
        "initiative_id" => initiative.id,
        "parent_id" => root.id,
        "title" => "Mid"
      })

    {:ok, leaf1} =
      Tasks.create_task(user, %{
        "initiative_id" => initiative.id,
        "parent_id" => mid.id,
        "title" => "L1",
        "weight" => "3"
      })

    {:ok, leaf2} =
      Tasks.create_task(user, %{
        "initiative_id" => initiative.id,
        "parent_id" => mid.id,
        "title" => "L2",
        "weight" => "1"
      })

    {:ok, _} = Tasks.update_task(leaf1, user, %{"manual_progress" => 100})
    {:ok, _} = Tasks.update_task(leaf2, user, %{"manual_progress" => 0})

    # mid: (100*3 + 0*1)/4 = 75
    refreshed_mid = Tasks.get_task!(mid.id)
    assert refreshed_mid.computed_progress == 75

    # root: just one child (mid) so it equals mid.
    refreshed_root = Tasks.get_task!(root.id)
    assert refreshed_root.computed_progress == 75
  end

  test "marking a leaf done forces 100 and propagates", %{user: user, initiative: initiative} do
    {:ok, root} = Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "Root"})

    {:ok, leaf} =
      Tasks.create_task(user, %{
        "initiative_id" => initiative.id,
        "parent_id" => root.id,
        "title" => "L"
      })

    {:ok, leaf2} = Tasks.update_task(leaf, user, %{"status" => "done"})

    assert leaf2.status == "done"
    assert leaf2.manual_progress == 100

    refreshed_root = Tasks.get_task!(root.id)
    assert refreshed_root.computed_progress == 100
  end

  test "activity events are recorded on create and update", %{user: user, initiative: initiative} do
    {:ok, task} =
      Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "Hi"})

    {:ok, _} = Tasks.update_task(task, user, %{"manual_progress" => 50})

    kinds = Tasks.list_task_activity(task.id) |> Enum.map(& &1.kind) |> Enum.sort()
    assert "created" in kinds
    assert "progress_changed" in kinds
  end
end
