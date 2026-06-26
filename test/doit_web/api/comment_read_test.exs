defmodule DoItWeb.Api.CommentReadTest do
  @moduledoc """
  Task comment reads (m03.01 worklist 2.3):
  `GET /api/v1/initiatives/:id/tasks/:task_id/comments`.

  A soft-deleted comment surfaces as a **tombstone** (per Q6 — not omitted).
  Authz: view on the owning Initiative (stranger → 403); a foreign task id (one
  not in this Initiative) → 404, never a cross-Initiative leak.
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

  defp token(user) do
    {:ok, {plaintext, _}} = Accounts.mint_api_token(user, "test")
    plaintext
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  setup do
    owner = user("owner")
    viewer = user("viewer")
    stranger = user("stranger")

    {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Q3 Launch"})
    {:ok, _} = Initiatives.add_member(ini.id, viewer.id, "viewer")

    {:ok, task} =
      Tasks.create_task(owner, %{
        "initiative_id" => ini.id,
        "parent_id" => ini.root_task_id,
        "title" => "Build API"
      })

    {:ok, _live} = Tasks.add_comment(task, owner, "looks good")
    {:ok, doomed} = Tasks.add_comment(task, owner, "never mind")
    {:ok, _} = Tasks.delete_comment(doomed.id, owner)

    # A foreign task in another Initiative the owner can't reach through this one.
    {:ok, other} = Initiatives.create_initiative(stranger, %{"name" => "Other"})

    {:ok, foreign} =
      Tasks.create_task(stranger, %{
        "initiative_id" => other.id,
        "parent_id" => other.root_task_id,
        "title" => "Foreign"
      })

    %{owner: owner, viewer: viewer, stranger: stranger, ini: ini, task: task, foreign: foreign}
  end

  test "returns live comments plus a tombstone for a soft-deleted one", ctx do
    conn =
      build_conn()
      |> bearer(token(ctx.owner))
      |> get(~p"/api/v1/initiatives/#{ctx.ini.id}/tasks/#{ctx.task.id}/comments")

    assert %{"data" => comments} = json_response(conn, 200)
    assert length(comments) == 2

    live = Enum.find(comments, &(&1["deleted"] == false))
    assert live["body"] == "looks good"
    assert live["author_id"] == ctx.owner.id
    assert is_binary(live["author_name"])

    tomb = Enum.find(comments, &(&1["deleted"] == true))
    # Tombstone: surfaced, but its content is suppressed.
    assert tomb["body"] == nil
    assert tomb["deleted_by_id"] == ctx.owner.id
    assert is_binary(tomb["deleted_at"])
  end

  test "a viewer-role token can read the comments", ctx do
    conn =
      build_conn()
      |> bearer(token(ctx.viewer))
      |> get(~p"/api/v1/initiatives/#{ctx.ini.id}/tasks/#{ctx.task.id}/comments")

    assert %{"data" => comments} = json_response(conn, 200)
    assert length(comments) == 2
  end

  test "a stranger is forbidden (403)", ctx do
    conn =
      build_conn()
      |> bearer(token(ctx.stranger))
      |> get(~p"/api/v1/initiatives/#{ctx.ini.id}/tasks/#{ctx.task.id}/comments")

    assert %{"error" => %{"status" => 403}} = json_response(conn, 403)
  end

  test "a foreign task id (not in this Initiative) is a 404", ctx do
    conn =
      build_conn()
      |> bearer(token(ctx.owner))
      |> get(~p"/api/v1/initiatives/#{ctx.ini.id}/tasks/#{ctx.foreign.id}/comments")

    assert %{"error" => %{"status" => 404}} = json_response(conn, 404)
  end

  test "a soft-deleted task in this Initiative is a 404 (aligned with the activity rollup)", ctx do
    {:ok, _} = Tasks.delete_task(ctx.task, ctx.owner)

    conn =
      build_conn()
      |> bearer(token(ctx.owner))
      |> get(~p"/api/v1/initiatives/#{ctx.ini.id}/tasks/#{ctx.task.id}/comments")

    assert %{"error" => %{"status" => 404}} = json_response(conn, 404)
  end
end
