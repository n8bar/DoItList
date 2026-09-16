defmodule DoItWeb.Api.OperationsHistoryTest do
  @moduledoc """
  The `add history` operation (m04.02 item 3.1.2) — undo and redo through the
  shared engine, so the browser client, an agent, and the LiveView all move one
  stack.

  Covers the delta each reversal answers with (`upserts` of every still-live
  task it changed, `removed` for the ones it took away), the kind it names, the
  empty-stack error, the role gate the context owns, and an idempotent replay.

  Each `post_ops` mints a fresh token, so the per-token rate limit (5/window in
  `config/test.exs`) never bites.
  """
  use DoItWeb.ConnCase, async: true

  alias DoIt.{Accounts, Initiatives, Tasks}

  defp user(name) do
    n = System.unique_integer([:positive])

    {:ok, u} =
      Accounts.register_user(%{
        "email" => "#{name}-#{n}@example.com",
        "username" => "#{name}-#{n}",
        "name" => String.capitalize(name),
        "password" => "password123"
      })

    u
  end

  defp token(user) do
    {:ok, {plaintext, _}} = Accounts.mint_api_token(user, "test")
    plaintext
  end

  defp post_ops(user, operations, key \\ nil) do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token(user))
      |> put_req_header("content-type", "application/json")
      |> maybe_key(key)
      |> post(~p"/api/v1/operations", %{"operations" => operations})

    {conn.status, json_response(conn, conn.status)}
  end

  defp maybe_key(conn, nil), do: conn
  defp maybe_key(conn, key), do: put_req_header(conn, "idempotency-key", key)

  defp history_op(ini, action),
    do: %{
      "op" => "add",
      "type" => "history",
      "data" => %{"initiative_id" => ini.id, "action" => action}
    }

  defp task(actor, ini, title, parent_id \\ nil) do
    {:ok, task} =
      Tasks.create_task(actor, %{
        "initiative_id" => ini.id,
        "parent_id" => parent_id || ini.root_task_id,
        "title" => title
      })

    task
  end

  defp upsert(body, id) do
    body
    |> get_in(["results", Access.at(0), "data", "upserts"])
    |> Enum.find(&(&1["id"] == id))
  end

  setup do
    owner = user("owner")
    editor = user("editor")
    viewer = user("viewer")

    {:ok, ini} =
      Initiatives.create_initiative(owner, %{"name" => "Q3 Launch"}, agent_access: true)

    {:ok, _} = Initiatives.add_member(ini.id, editor.id, "editor")
    {:ok, _} = Initiatives.add_member(ini.id, viewer.id, "viewer")

    %{owner: owner, editor: editor, viewer: viewer, ini: ini}
  end

  describe "undo" do
    test "a title change comes back, with the old title in upserts", ctx do
      phase = task(ctx.owner, ctx.ini, "Phase 1")
      {:ok, _} = Tasks.update_task(phase, ctx.owner, %{"title" => "Phase one"})

      {status, body} = post_ops(ctx.owner, [history_op(ctx.ini, "undo")])

      assert status == 200
      assert %{"results" => [%{"status" => "ok", "data" => data}]} = body
      assert data["type"] == "history"
      assert data["action"] == "undo"
      assert data["kind"] == "title_changed"
      assert data["removed"] == []
      assert upsert(body, phase.id)["title"] == "Phase 1"
      assert Tasks.get_task(phase.id).title == "Phase 1"
    end

    test "a create is reported as removed", ctx do
      _phase = task(ctx.owner, ctx.ini, "Phase 1")
      oops = task(ctx.owner, ctx.ini, "Oops")

      {status, body} = post_ops(ctx.owner, [history_op(ctx.ini, "undo")])

      assert status == 200
      assert %{"results" => [%{"data" => data}]} = body
      assert data["kind"] == "created"
      assert data["removed"] == [oops.id]
      refute Enum.any?(data["upserts"], &(&1["id"] == oops.id))
      assert Tasks.get_task(oops.id).deleted_at
    end

    test "a delete restores the whole subtree into upserts", ctx do
      phase = task(ctx.owner, ctx.ini, "Phase 1")
      child = task(ctx.owner, ctx.ini, "Child", phase.id)
      grandchild = task(ctx.owner, ctx.ini, "Grandchild", child.id)
      {:ok, _} = Tasks.delete_task(child, ctx.owner)

      {status, body} = post_ops(ctx.owner, [history_op(ctx.ini, "undo")])

      assert status == 200
      assert %{"results" => [%{"data" => data}]} = body
      assert data["kind"] == "child_deleted"
      assert data["removed"] == []
      assert upsert(body, child.id)["title"] == "Child"
      assert upsert(body, grandchild.id)["title"] == "Grandchild"
      refute Tasks.get_task(child.id).deleted_at
    end

    test "an ancestor whose roll-up moved rides along in upserts", ctx do
      phase = task(ctx.owner, ctx.ini, "Phase 1")
      leaf = task(ctx.owner, ctx.ini, "Leaf", phase.id)
      {:ok, _} = Tasks.update_task(leaf, ctx.owner, %{"manual_progress" => 60})

      {200, body} = post_ops(ctx.owner, [history_op(ctx.ini, "undo")])

      assert upsert(body, leaf.id)["manual_progress"] == 0
      assert upsert(body, phase.id)["progress"] == 0
    end

    test "an empty stack is a per-op error naming what it can't do", ctx do
      {status, body} = post_ops(ctx.owner, [history_op(ctx.ini, "undo")])

      assert status == 422

      assert %{
               "results" => [
                 %{
                   "status" => "error",
                   "error" => %{"code" => "unprocessable_entity", "message" => "nothing to undo"}
                 }
               ]
             } = body
    end

    test "a plain viewer cannot undo an editor's move", ctx do
      phase = task(ctx.editor, ctx.ini, "Phase 1")
      other = task(ctx.editor, ctx.ini, "Other")
      {:ok, _} = Tasks.move_task(phase, ctx.editor, %{"parent_id" => other.id})

      {status, body} = post_ops(ctx.viewer, [history_op(ctx.ini, "undo")])

      assert status == 422
      assert %{"results" => [%{"error" => %{"message" => "nothing to undo"}}]} = body
      assert Tasks.get_task(phase.id).parent_id == other.id

      # The editor's own undo still works — the wall is the viewer's role.
      {200, _} = post_ops(ctx.editor, [history_op(ctx.ini, "undo")])
      refute Tasks.get_task(phase.id).parent_id == other.id
    end

    test "an unknown action and an unknown data key are rejected", ctx do
      {422, sideways} =
        post_ops(ctx.owner, [
          %{
            "op" => "add",
            "type" => "history",
            "data" => %{"initiative_id" => ctx.ini.id, "action" => "sideways"}
          }
        ])

      assert %{"results" => [%{"error" => %{"pointer" => "action"}}]} = sideways

      {422, lid} =
        post_ops(ctx.owner, [
          %{
            "op" => "add",
            "type" => "history",
            "data" => %{"initiative_lid" => "i1", "action" => "undo"}
          }
        ])

      assert %{"results" => [%{"error" => %{"pointer" => "initiative_lid"}}]} = lid
    end

    test "a non-member is refused before anything is reversed", ctx do
      stranger = user("stranger")
      phase = task(ctx.owner, ctx.ini, "Phase 1")

      {status, body} = post_ops(stranger, [history_op(ctx.ini, "undo")])

      assert status == 403
      assert %{"results" => [%{"error" => %{"code" => "forbidden"}}]} = body
      refute Tasks.get_task(phase.id).deleted_at
    end
  end

  describe "redo" do
    test "re-applies what the undo took away", ctx do
      phase = task(ctx.owner, ctx.ini, "Phase 1")
      {:ok, _} = Tasks.update_task(phase, ctx.owner, %{"title" => "Phase one"})
      {:ok, _} = Tasks.undo(ctx.owner, ctx.ini.id)

      {status, body} = post_ops(ctx.owner, [history_op(ctx.ini, "redo")])

      assert status == 200
      assert %{"results" => [%{"data" => data}]} = body
      assert data["action"] == "redo"
      assert data["kind"] == "title_changed"
      assert upsert(body, phase.id)["title"] == "Phase one"
      assert Tasks.get_task(phase.id).title == "Phase one"
    end

    test "nothing undone is nothing to redo", ctx do
      _phase = task(ctx.owner, ctx.ini, "Phase 1")

      {status, body} = post_ops(ctx.owner, [history_op(ctx.ini, "redo")])

      assert status == 422
      assert %{"results" => [%{"error" => %{"message" => "nothing to redo"}}]} = body
    end
  end

  describe "idempotent retry" do
    test "the same key replays the stored body and undoes nothing further", ctx do
      phase = task(ctx.owner, ctx.ini, "Phase 1")
      {:ok, _} = Tasks.update_task(phase, ctx.owner, %{"title" => "Phase one"})

      key = "undo-#{System.unique_integer([:positive])}"
      {200, first} = post_ops(ctx.owner, [history_op(ctx.ini, "undo")], key)
      {200, replay} = post_ops(ctx.owner, [history_op(ctx.ini, "undo")], key)

      assert replay == first
      # A second real undo would have reversed the create; the title stands and
      # the task is still here.
      assert Tasks.get_task(phase.id).title == "Phase 1"
    end
  end
end
