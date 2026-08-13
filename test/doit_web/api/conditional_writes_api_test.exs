defmodule DoItWeb.Api.ConditionalWritesApiTest do
  @moduledoc """
  Conditional writes over `POST /api/v1/operations` (m03.04 item 32): a
  matching `expected_version` applies, a stale one 409s with the per-op
  `conflict` error carrying the current record and ZERO writes (whole batch
  rolled back), an omitted one keeps today's unconditional behavior. Plus the
  read side: `version` rides the tree, the task ref, and the Initiative
  summary.

  Persistence is checked through the domain contexts (the operations_test
  precedent) so the per-token rate limit never bites.
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

  defp post_ops(user, operations) do
    conn =
      build_conn()
      |> bearer(token(user))
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/v1/operations", %{"operations" => operations})

    {conn.status, json_response(conn, conn.status)}
  end

  setup do
    owner = user("owner")

    {:ok, ini} =
      Initiatives.create_initiative(owner, %{"name" => "Q3 Launch"}, agent_access: true)

    {:ok, task} =
      Tasks.create_task(owner, %{
        "initiative_id" => ini.id,
        "parent_id" => ini.root_task_id,
        "title" => "Build API",
        "description" => "original"
      })

    %{owner: owner, ini: ini, task: task}
  end

  describe "update task with expected_version" do
    test "a matching token applies and the echo carries the bumped version", ctx do
      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "update",
            "type" => "task",
            "id" => ctx.task.id,
            "data" => %{"description" => "sharpened", "expected_version" => 1}
          }
        ])

      assert status == 200
      assert [%{"status" => "ok", "data" => data}] = body["results"]
      assert data["version"] == 2
      assert Repo.get!(Task, ctx.task.id).description == "sharpened"
    end

    test "a stale token 409s with the conflict + current record and writes nothing", ctx do
      # The operator sharpens the description after the agent's read...
      {:ok, _} = Tasks.update_task(ctx.task, ctx.owner, %{"description" => "operator intent"})

      # ...then the agent writes with its stale version-1 token.
      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "update",
            "type" => "task",
            "id" => ctx.task.id,
            "data" => %{"description" => "stale agent text", "expected_version" => 1}
          }
        ])

      assert status == 409
      assert body["error"]["code"] == "conflict"

      assert [%{"status" => "error", "error" => op_error}] = body["results"]
      assert op_error["code"] == "conflict"
      assert op_error["pointer"] == "expected_version"

      # The conflict carries the CURRENT record — id, content, fresh version.
      assert %{"id" => id, "version" => 2} = op_error["current"]
      assert id == ctx.task.id

      # Zero writes: the operator's intent stands.
      assert Repo.get!(Task, ctx.task.id).description == "operator intent"
    end

    test "an omitted token keeps today's unconditional last-write-wins", ctx do
      {:ok, _} = Tasks.update_task(ctx.task, ctx.owner, %{"description" => "newer"})

      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "update",
            "type" => "task",
            "id" => ctx.task.id,
            "data" => %{"description" => "unconditional overwrite"}
          }
        ])

      assert status == 200
      assert [%{"status" => "ok"}] = body["results"]
      assert Repo.get!(Task, ctx.task.id).description == "unconditional overwrite"
    end

    test "the token guards every update concern — a stale done-flip conflicts too", ctx do
      {:ok, _} = Tasks.update_task(ctx.task, ctx.owner, %{"title" => "Renamed"})

      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "update",
            "type" => "task",
            "id" => ctx.task.id,
            "data" => %{"done" => true, "expected_version" => 1}
          }
        ])

      assert status == 409
      assert [%{"error" => %{"code" => "conflict"}}] = body["results"]
      assert Repo.get!(Task, ctx.task.id).status == "open"
    end

    test "a conflict mid-batch rolls the WHOLE batch back", ctx do
      {:ok, _} = Tasks.update_task(ctx.task, ctx.owner, %{"title" => "Renamed"})

      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "add",
            "type" => "task",
            "lid" => "t1",
            "data" => %{"initiative_id" => ctx.ini.id, "title" => "Never lands"}
          },
          %{
            "op" => "update",
            "type" => "task",
            "id" => ctx.task.id,
            "data" => %{"title" => "stale", "expected_version" => 1}
          }
        ])

      assert status == 409

      assert [%{"status" => "not_applied"}, %{"status" => "error"}] = body["results"]
      refute Repo.exists?(from t in Task, where: t.title == "Never lands")
    end

    test "a non-integer token is a 422 naming the field", ctx do
      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "update",
            "type" => "task",
            "id" => ctx.task.id,
            "data" => %{"title" => "X", "expected_version" => "one"}
          }
        ])

      assert status == 422
      assert [%{"error" => %{"pointer" => "expected_version"}}] = body["results"]
    end
  end

  describe "update initiative with expected_version" do
    test "matching applies, stale 409s with the current record, omitted unconditional", ctx do
      # Matching.
      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "update",
            "type" => "initiative",
            "id" => ctx.ini.id,
            "data" => %{"name" => "Renamed once", "expected_version" => 1}
          }
        ])

      assert status == 200
      assert [%{"data" => %{"version" => 2}}] = body["results"]

      # Stale (the token above is spent — the record is at 2 now).
      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "update",
            "type" => "initiative",
            "id" => ctx.ini.id,
            "data" => %{"name" => "stale rename", "expected_version" => 1}
          }
        ])

      assert status == 409
      assert [%{"error" => op_error}] = body["results"]
      assert op_error["code"] == "conflict"
      assert %{"name" => "Renamed once", "version" => 2} = op_error["current"]
      assert Initiatives.get_initiative(ctx.ini.id).name == "Renamed once"

      # Omitted.
      {status, _body} =
        post_ops(ctx.owner, [
          %{
            "op" => "update",
            "type" => "initiative",
            "id" => ctx.ini.id,
            "data" => %{"name" => "Unconditional"}
          }
        ])

      assert status == 200
      assert Initiatives.get_initiative(ctx.ini.id).name == "Unconditional"
    end
  end

  describe "version on the reads (32.1)" do
    test "tree header + task nodes and the task ref carry version", ctx do
      {:ok, _} = Tasks.update_task(ctx.task, ctx.owner, %{"description" => "bumped"})

      plaintext = token(ctx.owner)

      conn = build_conn() |> bearer(plaintext) |> get(~p"/api/v1/initiatives/#{ctx.ini.id}")
      assert %{"data" => tree} = json_response(conn, 200)
      assert tree["version"] == 1
      assert [%{"id" => task_id, "version" => 2}] = tree["tasks"]
      assert task_id == ctx.task.id

      conn = build_conn() |> bearer(plaintext) |> get(~p"/api/v1/tasks/#{ctx.task.id}")
      assert %{"data" => %{"version" => 2}} = json_response(conn, 200)

      conn = build_conn() |> bearer(plaintext) |> get(~p"/api/v1/initiatives")
      assert %{"data" => [%{"version" => 1}]} = json_response(conn, 200)
    end
  end
end
