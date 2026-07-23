defmodule DoItWeb.Api.TaskReadTest do
  @moduledoc """
  The task → Initiative resolver (m03.04 item 2.18.1): `GET /api/v1/tasks/:id`.

  View-gated through the task's Initiative, but UNIFORMLY 404: a garbage or
  unknown id, a soft-deleted task, agent access off, and a task the caller
  can't view all answer with the same 404 body — a bare task id is never an
  existence oracle (no 403 leak).
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

    {:ok, ini} =
      Initiatives.create_initiative(owner, %{"name" => "Q3 Launch"}, agent_access: true)

    {:ok, _} = Initiatives.add_member(ini.id, viewer.id, "viewer")

    {:ok, task} =
      Tasks.create_task(owner, %{
        "initiative_id" => ini.id,
        "parent_id" => ini.root_task_id,
        "title" => "Build API"
      })

    %{owner: owner, viewer: viewer, stranger: stranger, ini: ini, task: task}
  end

  test "the owner reads exactly {id, initiative_id}", ctx do
    conn = build_conn() |> bearer(token(ctx.owner)) |> get(~p"/api/v1/tasks/#{ctx.task.id}")

    assert %{"data" => data} = json_response(conn, 200)
    assert data == %{"id" => ctx.task.id, "initiative_id" => ctx.ini.id}
  end

  test "a viewer-role member can read it too", ctx do
    conn = build_conn() |> bearer(token(ctx.viewer)) |> get(~p"/api/v1/tasks/#{ctx.task.id}")

    assert %{"data" => %{"id" => id, "initiative_id" => ini_id}} = json_response(conn, 200)
    assert {id, ini_id} == {ctx.task.id, ctx.ini.id}
  end

  test "the root task resolves — it's the parent_id a top-level add anchors on", ctx do
    conn =
      build_conn() |> bearer(token(ctx.owner)) |> get(~p"/api/v1/tasks/#{ctx.ini.root_task_id}")

    assert %{"data" => %{"id" => id, "initiative_id" => ini_id}} = json_response(conn, 200)
    assert {id, ini_id} == {ctx.ini.root_task_id, ctx.ini.id}
  end

  test "a non-member gets the SAME 404 body as an unknown id — no existence oracle", ctx do
    stranger_conn =
      build_conn() |> bearer(token(ctx.stranger)) |> get(~p"/api/v1/tasks/#{ctx.task.id}")

    unknown_conn =
      build_conn() |> bearer(token(ctx.stranger)) |> get(~p"/api/v1/tasks/99999999")

    assert %{"error" => %{"status" => 404}} = stranger_body = json_response(stranger_conn, 404)
    assert unknown_body = json_response(unknown_conn, 404)
    assert stranger_body == unknown_body
  end

  test "an unknown id and a garbage id are 404", ctx do
    tok = token(ctx.owner)

    unknown = build_conn() |> bearer(tok) |> get(~p"/api/v1/tasks/99999999")
    garbage = build_conn() |> bearer(tok) |> get("/api/v1/tasks/not-an-id")

    assert %{"error" => %{"status" => 404}} = json_response(unknown, 404)
    assert %{"error" => %{"status" => 404}} = json_response(garbage, 404)
  end

  test "a soft-deleted task is a 404 (aligned with the rest of the read surface)", ctx do
    {:ok, _} = Tasks.delete_task(ctx.task, ctx.owner)

    conn = build_conn() |> bearer(token(ctx.owner)) |> get(~p"/api/v1/tasks/#{ctx.task.id}")

    assert %{"error" => %{"status" => 404}} = json_response(conn, 404)
  end

  test "agent access off hides the task from everyone — 404 even for the owner", ctx do
    owner = ctx.owner
    {:ok, off} = Initiatives.create_initiative(owner, %{"name" => "Private"})

    {:ok, hidden} =
      Tasks.create_task(owner, %{
        "initiative_id" => off.id,
        "parent_id" => off.root_task_id,
        "title" => "Hidden"
      })

    conn = build_conn() |> bearer(token(owner)) |> get(~p"/api/v1/tasks/#{hidden.id}")

    assert %{"error" => %{"status" => 404}} = json_response(conn, 404)
  end
end
