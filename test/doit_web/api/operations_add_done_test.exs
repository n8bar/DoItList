defmodule DoItWeb.Api.OperationsAddDoneTest do
  @moduledoc """
  `done` on `add task` (m03.04 2.5.4): one completion word across add and
  update. A completed source item is ONE op — the add lands done, snaps its
  progress, and reconciles its ancestors exactly like a post-create flip
  would; a non-boolean gets the update op's own 422.
  """
  use DoItWeb.ConnCase, async: true

  alias DoIt.{Accounts, Initiatives, Tasks}
  alias DoIt.Tasks.Task

  defp user do
    {:ok, u} =
      Accounts.register_user(%{
        "email" => "adddone-#{System.unique_integer([:positive])}@example.com",
        "username" => "adddone-#{System.unique_integer([:positive])}",
        "name" => "Add Done",
        "password" => "password123"
      })

    u
  end

  defp post_ops(user, operations) do
    {:ok, {token, _}} = Accounts.mint_api_token(user, "test")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/v1/operations", %{"operations" => operations})

    {conn.status, json_response(conn, conn.status)}
  end

  setup do
    owner = user()
    {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Import"}, agent_access: true)
    %{owner: owner, ini: ini}
  end

  test "an add with done: true lands done, snapped to 100, and completes its parent", ctx do
    {status, body} =
      post_ops(ctx.owner, [
        %{
          "op" => "add",
          "type" => "task",
          "lid" => "branch",
          "data" => %{"initiative_id" => ctx.ini.id, "title" => "Branch"}
        },
        %{
          "op" => "add",
          "type" => "task",
          "lid" => "leaf",
          "data" => %{
            "parent_lid" => "branch",
            "title" => "Only leaf, already done",
            "done" => true
          }
        }
      ])

    assert status == 200
    assert [%{"data" => branch}, %{"data" => leaf}] = body["results"]

    # The leaf: done in the response and in the row, progress snapped like a flip.
    assert leaf["done"] == true
    assert %Task{status: "done", manual_progress: 100} = Tasks.get_task(leaf["id"])

    # The branch: its only child arrived done, so the create reconciled it — the
    # same ancestor completion a post-create `update done: true` would have made.
    assert %Task{status: "done", computed_progress: 100} = Tasks.get_task(branch["id"])
  end

  test "an add with done: false stays open; a non-boolean 422s with the update op's message",
       ctx do
    {200, body} =
      post_ops(ctx.owner, [
        %{
          "op" => "add",
          "type" => "task",
          "data" => %{"initiative_id" => ctx.ini.id, "title" => "Open", "done" => false}
        }
      ])

    assert [%{"data" => %{"done" => false, "id" => id}}] = body["results"]
    assert %Task{status: "open"} = Tasks.get_task(id)

    {422, body} =
      post_ops(ctx.owner, [
        %{
          "op" => "add",
          "type" => "task",
          "data" => %{"initiative_id" => ctx.ini.id, "title" => "Bad", "done" => "yes"}
        }
      ])

    assert [%{"status" => "error", "error" => %{"message" => message, "pointer" => "done"}}] =
             body["results"]

    assert message == "\"done\" must be true or false."
  end
end
