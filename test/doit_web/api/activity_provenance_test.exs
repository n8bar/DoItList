defmodule DoItWeb.Api.ActivityProvenanceTest do
  @moduledoc """
  Execution provenance on activity events (m03.04 item 2.33): a browser-session
  write records `actor_kind: "browser"`; a token-borne write records the token
  (kind + id + label snapshotted at write time); both serialize on
  `GET /api/v1/initiatives/:id/activity`; legacy pre-provenance rows (null
  `actor_kind`) still serialize; and the snapshotted label survives token
  revocation (the FK nilifies, the label stays).
  """
  use DoItWeb.ConnCase, async: true

  alias DoIt.{Accounts, Initiatives, Tasks}
  alias DoIt.Repo
  alias DoIt.Tasks.ActivityEvent

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

  # The serialized activity list for `ini_id`, read with `token`.
  defp activity(token, ini_id) do
    build_conn()
    |> bearer(token)
    |> get(~p"/api/v1/initiatives/#{ini_id}/activity?limit=200")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp event_row(task_id, kind) do
    Repo.get_by!(ActivityEvent, task_id: task_id, kind: kind)
  end

  # POST a single add-task op with `token`; returns the new task's id.
  defp post_add_task(token, ini, title) do
    conn =
      build_conn()
      |> bearer(token)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/v1/operations", %{
        "operations" => [
          %{
            "op" => "add",
            "type" => "task",
            "lid" => "t1",
            "data" => %{
              "initiative_id" => ini.id,
              "parent_id" => ini.root_task_id,
              "title" => title
            }
          }
        ]
      })

    body = json_response(conn, 200)
    [%{"status" => "ok", "data" => %{"id" => task_id}}] = body["results"]
    task_id
  end

  setup do
    owner = user("owner")

    {:ok, ini} =
      Initiatives.create_initiative(owner, %{"name" => "Provenance"}, agent_access: true)

    {:ok, {plaintext, tok}} = Accounts.mint_api_token(owner, "planning agent")
    %{owner: owner, ini: ini, plaintext: plaintext, tok: tok}
  end

  test "a browser-session write records browser provenance and serializes it", ctx do
    {:ok, task} =
      Tasks.create_task(ctx.owner, %{
        "initiative_id" => ctx.ini.id,
        "parent_id" => ctx.ini.root_task_id,
        "title" => "Typed by hand"
      })

    row = event_row(task.id, "created")
    assert row.actor_kind == "browser"
    assert row.api_token_id == nil
    assert row.api_token_label == nil

    event = ctx.plaintext |> activity(ctx.ini.id) |> Enum.find(&(&1["task_id"] == task.id))
    assert event["actor_kind"] == "browser"
    assert event["api_token_id"] == nil
    assert event["api_token_label"] == nil
  end

  test "a token-borne write records the token and serializes its identity", ctx do
    task_id = post_add_task(ctx.plaintext, ctx.ini, "Written by agent")

    row = event_row(task_id, "created")
    assert row.actor_kind == "api_token"
    assert row.api_token_id == ctx.tok.id
    assert row.api_token_label == "planning agent"

    event = ctx.plaintext |> activity(ctx.ini.id) |> Enum.find(&(&1["task_id"] == task_id))
    assert event["actor_kind"] == "api_token"
    assert event["api_token_id"] == ctx.tok.id
    assert event["api_token_label"] == "planning agent"
  end

  test "legacy pre-provenance events serialize with null provenance", ctx do
    legacy =
      Repo.insert!(%ActivityEvent{
        task_id: ctx.ini.root_task_id,
        initiative_id: ctx.ini.id,
        user_id: ctx.owner.id,
        kind: "title_changed",
        data: %{"from" => "a", "to" => "b"}
      })

    event = ctx.plaintext |> activity(ctx.ini.id) |> Enum.find(&(&1["id"] == legacy.id))
    assert event["actor_kind"] == nil
    assert event["api_token_id"] == nil
    assert event["api_token_label"] == nil
  end

  test "the snapshotted label survives token revocation", ctx do
    {:ok, agent, _id} = Accounts.resolve_api_token(ctx.plaintext)

    {:ok, task} =
      Tasks.create_task(agent, %{
        "initiative_id" => ctx.ini.id,
        "parent_id" => ctx.ini.root_task_id,
        "title" => "Before revoke"
      })

    {:ok, _} = Accounts.revoke_api_token(ctx.owner, ctx.tok.id)

    row = event_row(task.id, "created")
    assert row.actor_kind == "api_token"
    # FK nilified by the delete; the write-time label snapshot remains.
    assert row.api_token_id == nil
    assert row.api_token_label == "planning agent"
  end
end
