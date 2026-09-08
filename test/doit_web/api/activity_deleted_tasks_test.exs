defmodule DoItWeb.Api.ActivityDeletedTasksTest do
  @moduledoc """
  The activity endpoint hides soft-deleted Tasks (m03.04 O&C 6.3). A reader
  can't open a deleted Task, so `GET /api/v1/initiatives/:id/activity` — and
  the MCP `get_initiative_activity` tool and `initiative_activity` resource,
  which read through this endpoint — omit its events, comments included.
  Restoring the Task returns them. Subtree scoping on a deleted `?task_id=`
  keeps its existing 404.
  """
  use DoItWeb.ConnCase, async: true

  alias DoIt.{Accounts, Initiatives, Tasks}

  defp user(name) do
    {:ok, u} =
      Accounts.register_user(%{
        "email" => "#{name}-#{System.unique_integer([:positive])}@example.com",
        "username" => "#{name}-#{System.unique_integer([:positive])}",
        "name" => String.capitalize(name),
        "password" => "password123"
      })

    u
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp activity_response(token, ini_id, params \\ []) do
    params = Keyword.put_new(params, :limit, 200)

    build_conn()
    |> bearer(token)
    |> get(~p"/api/v1/initiatives/#{ini_id}/activity?#{params}")
  end

  defp activity(token, ini_id, params \\ []) do
    token |> activity_response(ini_id, params) |> json_response(200) |> Map.fetch!("data")
  end

  defp create_task!(owner, ini, parent_id, title) do
    {:ok, task} =
      Tasks.create_task(owner, %{
        "initiative_id" => ini.id,
        "parent_id" => parent_id,
        "title" => title
      })

    task
  end

  setup do
    owner = user("owner")

    {:ok, ini} =
      Initiatives.create_initiative(owner, %{"name" => "Deleted tasks"}, agent_access: true)

    {:ok, {plaintext, _tok}} = Accounts.mint_api_token(owner, "planning agent")

    doomed = create_task!(owner, ini, ini.root_task_id, "Doomed")
    survivor = create_task!(owner, ini, ini.root_task_id, "Survivor")

    {:ok, doomed} = Tasks.update_task(doomed, owner, %{"title" => "Doomed (renamed)"})
    {:ok, _} = Tasks.toggle_complete(doomed, owner)
    {:ok, _} = Tasks.add_comment(doomed, owner, "a note on the doomed task")
    {:ok, _} = Tasks.add_comment(survivor, owner, "a note on the survivor")

    %{owner: owner, ini: ini, plaintext: plaintext, doomed: doomed, survivor: survivor}
  end

  test "deleting a task hides its events; restoring returns them", ctx do
    %{owner: owner, ini: ini, plaintext: token, doomed: doomed, survivor: survivor} = ctx

    before_ids = for e <- activity(token, ini.id), e["task_id"] == doomed.id, do: e["id"]
    survivor_before = for e <- activity(token, ini.id), e["task_id"] == survivor.id, do: e["id"]

    assert length(before_ids) >= 4

    assert Enum.any?(
             activity(token, ini.id),
             &(&1["task_id"] == doomed.id and &1["kind"] == "commented")
           )

    {:ok, _} = Tasks.delete_task(doomed, owner)

    after_delete = activity(token, ini.id)
    refute Enum.any?(after_delete, &(&1["task_id"] == doomed.id))

    # The live task's events are unchanged, comment event included.
    assert for(e <- after_delete, e["task_id"] == survivor.id, do: e["id"]) == survivor_before

    assert Enum.any?(
             after_delete,
             &(&1["task_id"] == survivor.id and &1["kind"] == "commented")
           )

    # The delete itself is still reported — it lives on the surviving parent.
    assert Enum.any?(
             after_delete,
             &(&1["kind"] == "child_deleted" and &1["task_id"] == ini.root_task_id)
           )

    {:ok, _} = Tasks.restore_tasks([doomed.id], ini.root_task_id, ini.id)

    restored = for e <- activity(token, ini.id), e["task_id"] == doomed.id, do: e["id"]
    assert restored == before_ids
  end

  test "meta pagination counts only visible rows", ctx do
    %{owner: owner, ini: ini, plaintext: token, doomed: doomed} = ctx

    {:ok, _} = Tasks.delete_task(doomed, owner)

    visible = length(activity(token, ini.id))

    body =
      token
      |> activity_response(ini.id)
      |> json_response(200)

    assert body["meta"]["has_more"] == false
    assert length(body["data"]) == visible

    short =
      token
      |> activity_response(ini.id, limit: visible - 1)
      |> json_response(200)

    assert short["meta"]["has_more"] == true
    assert length(short["data"]) == visible - 1
    refute Enum.any?(short["data"], &(&1["task_id"] == doomed.id))
  end

  test "subtree scoping on a deleted task keeps its existing not-found behavior", ctx do
    %{owner: owner, ini: ini, plaintext: token, doomed: doomed} = ctx

    # Live: the subtree scope resolves and returns that task's events.
    live = activity(token, ini.id, task_id: doomed.id)
    assert Enum.all?(live, &(&1["task_id"] == doomed.id))
    assert live != []

    {:ok, _} = Tasks.delete_task(doomed, owner)

    assert token |> activity_response(ini.id, task_id: doomed.id) |> json_response(404)

    {:ok, _} = Tasks.restore_tasks([doomed.id], ini.root_task_id, ini.id)

    restored = activity(token, ini.id, task_id: doomed.id)
    assert Enum.map(restored, & &1["id"]) == Enum.map(live, & &1["id"])
  end
end
