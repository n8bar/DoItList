defmodule DoItWeb.Api.TaskCountTest do
  @moduledoc """
  The recent-pressure fact (m03.04 3.1 iteration 2):
  `GET /api/v1/initiatives/:id/task_count?created_at=<ISO8601>` — live task
  count (root excluded), optionally only tasks created at/after the given
  instant. A dumb fact: the MCP import gate derives its trailing window from
  it, so the window length stays adapter policy.
  """
  use DoItWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  alias DoIt.{Accounts, Initiatives, Repo, Tasks}
  alias DoIt.Tasks.Task

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

  defp add_task(owner, ini, title) do
    {:ok, task} =
      Tasks.create_task(owner, %{
        "initiative_id" => ini.id,
        "parent_id" => ini.root_task_id,
        "title" => title
      })

    task
  end

  setup do
    owner = user("owner")

    {:ok, ini} =
      Initiatives.create_initiative(owner, %{"name" => "Pressure"}, agent_access: true)

    %{owner: owner, ini: ini}
  end

  test "counts live tasks, root excluded; deleted tasks don't count", ctx do
    add_task(ctx.owner, ctx.ini, "One")
    add_task(ctx.owner, ctx.ini, "Two")
    doomed = add_task(ctx.owner, ctx.ini, "Doomed")
    {:ok, _} = Tasks.delete_task(doomed, ctx.owner)

    conn =
      build_conn()
      |> bearer(token(ctx.owner))
      |> get(~p"/api/v1/initiatives/#{ctx.ini.id}/task_count")

    assert %{"data" => %{"count" => 2}} = json_response(conn, 200)
  end

  test "created_at scopes the count to the window", ctx do
    old = add_task(ctx.owner, ctx.ini, "Old")

    # Age the first task out of the window by backdating its inserted_at.
    hour_ago = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

    {1, _} =
      Repo.update_all(
        from(t in Task, where: t.id == ^old.id),
        set: [inserted_at: hour_ago]
      )

    add_task(ctx.owner, ctx.ini, "Fresh")

    since = DateTime.utc_now() |> DateTime.add(-600, :second) |> DateTime.to_iso8601()

    conn =
      build_conn()
      |> bearer(token(ctx.owner))
      |> get(~p"/api/v1/initiatives/#{ctx.ini.id}/task_count?created_at=#{since}")

    assert %{"data" => %{"count" => 1}} = json_response(conn, 200)
  end

  test "a malformed created_at is a 422 naming the format", ctx do
    conn =
      build_conn()
      |> bearer(token(ctx.owner))
      |> get(~p"/api/v1/initiatives/#{ctx.ini.id}/task_count?created_at=yesterday")

    assert %{"error" => %{"message" => message}} = json_response(conn, 422)
    assert message =~ "ISO 8601"
  end

  test "view-gated like the other initiative reads: stranger 403, unknown 404", ctx do
    stranger = user("stranger")

    conn =
      build_conn()
      |> bearer(token(stranger))
      |> get(~p"/api/v1/initiatives/#{ctx.ini.id}/task_count")

    assert json_response(conn, 403)

    conn =
      build_conn()
      |> bearer(token(ctx.owner))
      |> get(~p"/api/v1/initiatives/999999999/task_count")

    assert json_response(conn, 404)
  end
end
