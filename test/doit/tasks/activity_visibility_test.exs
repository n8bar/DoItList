defmodule DoIt.Tasks.ActivityVisibilityTest do
  @moduledoc """
  Activity hides soft-deleted Tasks (m03.04 O&C 6.3). A reader can't open a
  deleted Task, so its events — comments included — drop out of the shared
  activity queries that feed the workspace pane, the HTTP API, and the MCP
  tool / resource that read through the API. Restoring the Task brings its
  history back, in order, with no bookkeeping. Live Tasks are untouched.
  """
  use DoIt.DataCase, async: true

  alias DoIt.{Accounts, Initiatives, Tasks}

  setup do
    {:ok, owner} =
      Accounts.register_user(%{
        "email" => "owner-#{System.unique_integer([:positive])}@example.com",
        "username" => "owner-#{System.unique_integer([:positive])}",
        "name" => "Owner",
        "password" => "password123"
      })

    {:ok, initiative} = Initiatives.create_initiative(owner, %{"name" => "Visibility"})

    doomed = task!(owner, initiative, "Doomed")
    survivor = task!(owner, initiative, "Survivor")

    # A spread of kinds on each, so the filter is exercised past `created`.
    {:ok, doomed} = Tasks.update_task(doomed, owner, %{"title" => "Doomed (renamed)"})
    {:ok, _} = Tasks.toggle_complete(doomed, owner)
    {:ok, _} = Tasks.add_comment(doomed, owner, "a note on the doomed task")

    {:ok, survivor} = Tasks.update_task(survivor, owner, %{"title" => "Survivor (renamed)"})
    {:ok, _} = Tasks.add_comment(survivor, owner, "a note on the survivor")

    %{owner: owner, initiative: initiative, doomed: doomed, survivor: survivor}
  end

  defp task!(owner, initiative, title) do
    {:ok, task} =
      Tasks.create_task(owner, %{
        "initiative_id" => initiative.id,
        "parent_id" => initiative.root_task_id,
        "title" => title
      })

    task
  end

  # Every event on `task_id` in the Initiative rollup, oldest-page-first order
  # preserved as returned.
  defp rollup_ids(initiative, task_id) do
    %{events: events} = Tasks.list_initiative_activity(initiative.id, limit: 200)
    for e <- events, e.task_id == task_id, do: e.id
  end

  test "a soft-deleted task's events leave the Initiative rollup and its own pane", ctx do
    %{owner: owner, initiative: ini, doomed: doomed, survivor: survivor} = ctx

    before_doomed = rollup_ids(ini, doomed.id)
    before_survivor = rollup_ids(ini, survivor.id)

    # The comment event is among what must disappear.
    assert length(before_doomed) >= 4
    assert Enum.any?(Tasks.list_task_activity(doomed.id), &(&1.kind == "commented"))

    {:ok, _} = Tasks.delete_task(doomed, owner)

    assert rollup_ids(ini, doomed.id) == []
    assert Tasks.list_task_activity(doomed.id) == []

    # The live task is untouched, kinds and all.
    assert rollup_ids(ini, survivor.id) == before_survivor
    assert Enum.any?(Tasks.list_task_activity(survivor.id), &(&1.kind == "commented"))

    # Restoring returns the same rows in the same order.
    {:ok, _} = Tasks.restore_tasks([doomed.id], ini.root_task_id, ini.id)

    assert rollup_ids(ini, doomed.id) == before_doomed
    assert Enum.any?(Tasks.list_task_activity(doomed.id), &(&1.kind == "commented"))
    assert rollup_ids(ini, survivor.id) == before_survivor
  end

  test "deleting a branch hides the whole subtree's events", ctx do
    %{owner: owner, initiative: ini} = ctx

    branch = task!(owner, ini, "Branch")

    {:ok, leaf} =
      Tasks.create_task(owner, %{
        "initiative_id" => ini.id,
        "parent_id" => branch.id,
        "title" => "Leaf"
      })

    {:ok, _} = Tasks.add_comment(leaf, owner, "leaf note")

    assert rollup_ids(ini, leaf.id) != []
    before_leaf = rollup_ids(ini, leaf.id)

    {:ok, _} = Tasks.delete_task(branch, owner)

    assert rollup_ids(ini, branch.id) == []
    assert rollup_ids(ini, leaf.id) == []
    assert Tasks.list_task_activity(leaf.id) == []

    {:ok, _} = Tasks.restore_tasks([branch.id, leaf.id], ini.root_task_id, ini.id)
    assert rollup_ids(ini, leaf.id) == before_leaf
  end

  test "the delete event itself stays — it lives on the surviving parent", ctx do
    %{owner: owner, initiative: ini, doomed: doomed} = ctx

    {:ok, _} = Tasks.delete_task(doomed, owner)

    %{events: events} = Tasks.list_initiative_activity(ini.id, limit: 200)
    deletion = Enum.find(events, &(&1.kind == "child_deleted"))

    assert deletion
    assert deletion.task_id == ini.root_task_id
  end

  test "pagination counts only visible rows", ctx do
    %{owner: owner, initiative: ini, doomed: doomed} = ctx

    %{events: all_events} = Tasks.list_initiative_activity(ini.id, limit: 200)
    doomed_count = Enum.count(all_events, &(&1.task_id == doomed.id))
    visible_after = length(all_events) - doomed_count

    {:ok, _} = Tasks.delete_task(doomed, owner)

    # `child_deleted` adds one event on the parent when the delete lands.
    %{events: events, has_more: has_more} =
      Tasks.list_initiative_activity(ini.id, limit: 200)

    assert length(events) == visible_after + 1
    refute has_more
    refute Enum.any?(events, &(&1.task_id == doomed.id))

    # The has_more probe fetches limit + 1 *visible* rows, so a page sized to
    # exactly the visible set reports no more.
    total = length(events)

    assert %{events: page, has_more: false} =
             Tasks.list_initiative_activity(ini.id, limit: total)

    assert length(page) == total

    assert %{events: short_page, has_more: true} =
             Tasks.list_initiative_activity(ini.id, limit: total - 1)

    assert length(short_page) == total - 1
  end

  test "subtree scoping via :task_ids also hides deleted tasks", ctx do
    %{owner: owner, initiative: ini, doomed: doomed} = ctx

    ids = Tasks.subtree_ids(doomed.id)
    assert %{events: [_ | _]} = Tasks.list_initiative_activity(ini.id, task_ids: ids)

    {:ok, _} = Tasks.delete_task(doomed, owner)

    assert %{events: []} = Tasks.list_initiative_activity(ini.id, task_ids: ids)
  end
end
