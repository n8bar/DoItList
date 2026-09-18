defmodule DoItWeb.Api.OperationsMoveManyTest do
  @moduledoc """
  `update task` with op-level `ids` (m04.02 item 2.1.2) — an ordered list of
  tasks moves under one parent through `Tasks.move_tasks/3` as one op, one
  event, one undo step.

  Covers: the block lands in list order with `records` in that order; `position`
  and `parent_lid` honored; the envelope rejections (`id` with `ids`, empty
  `ids`, a non-integer entry, a non-move data key); a cycle rolling the batch
  back; the role gate; a task in another Initiative failing exactly like a
  single unreachable id; undo through `add history`; an idempotent replay.

  Each `post_ops` mints a fresh token, so the per-token rate limit (5/window in
  `config/test.exs`) never bites.
  """
  use DoItWeb.ConnCase, async: true

  alias DoIt.{Accounts, Initiatives, Repo, Tasks}
  alias DoIt.Tasks.Task

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

  defp task(actor, ini, title, parent_id \\ nil) do
    {:ok, task} =
      Tasks.create_task(actor, %{
        "initiative_id" => ini.id,
        "parent_id" => parent_id || ini.root_task_id,
        "title" => title
      })

    task
  end

  defp move_many(ids, data),
    do: %{"op" => "update", "type" => "task", "ids" => ids, "data" => data}

  defp child_ids(parent_id), do: Tasks.ordered_child_ids(parent_id)

  # Two source parents with three children each, plus an empty destination.
  defp three_parents(owner, ini) do
    a = task(owner, ini, "A")
    b = task(owner, ini, "B")
    c = task(owner, ini, "C")
    [a1, a2, a3] = for t <- ~w(a1 a2 a3), do: task(owner, ini, t, a.id)
    [b1, b2, b3] = for t <- ~w(b1 b2 b3), do: task(owner, ini, t, b.id)
    %{a: a, b: b, c: c, a1: a1, a2: a2, a3: a3, b1: b1, b2: b2, b3: b3}
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

  describe "moving many" do
    test "three tasks from two parents land under a third in list order, records in order",
         ctx do
      %{a: a, b: b, c: c, a1: a1, a2: a2, a3: a3, b1: b1, b2: b2, b3: b3} =
        three_parents(ctx.owner, ctx.ini)

      key = "idem-#{System.unique_integer([:positive])}"
      ops = [move_many([b3.id, a2.id, b1.id], %{"parent_id" => c.id})]

      {status, body} = post_ops(ctx.editor, ops, key)

      assert status == 200
      assert [%{"index" => 0, "status" => "ok", "data" => data}] = body["results"]
      assert data["type"] == "task"
      assert data["id"] == b3.id

      assert [%{"id" => r1}, %{"id" => r2}, %{"id" => r3}] = data["records"]
      assert [r1, r2, r3] == [b3.id, a2.id, b1.id]
      assert Enum.all?(data["records"], &(&1["parent_id"] == c.id and &1["type"] == "task"))

      assert child_ids(c.id) == [b3.id, a2.id, b1.id]
      assert child_ids(a.id) == [a1.id, a3.id]
      assert child_ids(b.id) == [b2.id]

      # Same key, same payload: a byte-identical replay, nothing moves again.
      {s2, b2} = post_ops(ctx.editor, ops, key)
      assert s2 == 200
      assert b2 == body
      assert child_ids(c.id) == [b3.id, a2.id, b1.id]
    end

    test "position places the block among the destination's children", ctx do
      %{a: a, c: c, a1: a1, a3: a3} = three_parents(ctx.owner, ctx.ini)
      c1 = task(ctx.owner, ctx.ini, "c1", c.id)
      c2 = task(ctx.owner, ctx.ini, "c2", c.id)

      {status, _body} =
        post_ops(ctx.owner, [
          move_many([a3.id, a1.id], %{"parent_id" => c.id, "position" => 1})
        ])

      assert status == 200
      assert child_ids(c.id) == [c1.id, a3.id, a1.id, c2.id]
      assert child_ids(a.id) == [Repo.get_by!(Task, title: "a2").id]
    end

    test "ids in an order unlike their current slots land in that order (2.2)", ctx do
      %{a: a, c: c, a1: a1, a2: a2, a3: a3} = three_parents(ctx.owner, ctx.ini)
      c1 = task(ctx.owner, ctx.ini, "c1", c.id)

      {:ok, _} =
        Tasks.move_task(a3, ctx.owner, %{"parent_id" => a.id, "position" => 0, "reorder" => true})

      assert child_ids(a.id) == [a3.id, a1.id, a2.id]

      {status, body} =
        post_ops(ctx.owner, [
          move_many([a3.id, a1.id, a2.id], %{"parent_id" => c.id, "position" => 1})
        ])

      assert status == 200
      assert [%{"status" => "ok", "data" => %{"records" => records}}] = body["results"]
      assert Enum.map(records, & &1["id"]) == [a3.id, a1.id, a2.id]
      assert child_ids(c.id) == [c1.id, a3.id, a1.id, a2.id]
      assert child_ids(a.id) == []
    end

    test "parent_lid targets a parent added earlier in the same batch", ctx do
      %{a1: a1, b2: b2} = three_parents(ctx.owner, ctx.ini)

      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "add",
            "type" => "task",
            "lid" => "p",
            "data" => %{"initiative_id" => ctx.ini.id, "title" => "New parent"}
          },
          move_many([a1.id, b2.id], %{"parent_lid" => "p"})
        ])

      assert status == 200
      assert [%{"data" => %{"id" => parent_id}}, %{"status" => "ok"}] = body["results"]
      assert child_ids(parent_id) == [a1.id, b2.id]
    end
  end

  describe "envelope rejections" do
    test "id together with ids is a 422 pointing at ids", ctx do
      %{a1: a1, c: c} = three_parents(ctx.owner, ctx.ini)

      op = Map.put(move_many([a1.id], %{"parent_id" => c.id}), "id", a1.id)
      {status, body} = post_ops(ctx.owner, [op])

      assert status == 422
      assert [%{"status" => "error", "error" => error}] = body["results"]
      assert error["code"] == "unprocessable_entity"
      assert error["pointer"] == "ids"
      assert child_ids(c.id) == []
    end

    test "an empty ids is a 422", ctx do
      %{c: c} = three_parents(ctx.owner, ctx.ini)

      {status, body} = post_ops(ctx.owner, [move_many([], %{"parent_id" => c.id})])

      assert status == 422

      assert [%{"error" => %{"code" => "unprocessable_entity", "pointer" => "ids"}}] =
               body["results"]
    end

    test "a non-integer entry is a 422 pointing at ids", ctx do
      %{a1: a1, c: c} = three_parents(ctx.owner, ctx.ini)

      {status, body} =
        post_ops(ctx.owner, [move_many([a1.id, "t1"], %{"parent_id" => c.id})])

      assert status == 422

      assert [%{"error" => %{"code" => "unprocessable_entity", "pointer" => "ids"}}] =
               body["results"]

      assert child_ids(c.id) == []
    end

    test "a data key beyond the move is a 422 saying a many-task update only moves", ctx do
      %{a1: a1, c: c} = three_parents(ctx.owner, ctx.ini)

      {status, body} =
        post_ops(ctx.owner, [move_many([a1.id], %{"parent_id" => c.id, "done" => true})])

      assert status == 422
      assert [%{"error" => error}] = body["results"]
      assert error["code"] == "unprocessable_entity"
      assert error["pointer"] == "done"
      assert error["message"] =~ "only moves"
      assert Repo.get!(Task, a1.id).status != "done"
    end
  end

  describe "all-or-nothing" do
    test "a cycle moves nothing and rolls the batch back", ctx do
      %{a: a, a1: a1, b2: b2} = three_parents(ctx.owner, ctx.ini)

      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "add",
            "type" => "task",
            "data" => %{"initiative_id" => ctx.ini.id, "title" => "Rolled back"}
          },
          move_many([b2.id, a.id], %{"parent_id" => a1.id})
        ])

      assert status == 422

      assert [%{"status" => "not_applied"}, %{"status" => "error", "error" => error}] =
               body["results"]

      assert error["code"] == "unprocessable_entity"
      assert error["pointer"] == "parent_id"

      refute Repo.get_by(Task, title: "Rolled back")
      assert Repo.get!(Task, b2.id).parent_id != a1.id
      assert Repo.get!(Task, a.id).parent_id == ctx.ini.root_task_id
    end
  end

  describe "authorization" do
    test "a viewer is refused with 403 and nothing moves", ctx do
      %{a1: a1, c: c} = three_parents(ctx.owner, ctx.ini)

      {status, body} = post_ops(ctx.viewer, [move_many([a1.id], %{"parent_id" => c.id})])

      assert status == 403
      assert [%{"status" => "error", "error" => %{"code" => "forbidden"}}] = body["results"]
      assert child_ids(c.id) == []
    end

    test "an id in another Initiative fails exactly like a single unreachable id", ctx do
      %{a1: a1, c: c} = three_parents(ctx.owner, ctx.ini)
      stranger = user("stranger")

      {:ok, other} =
        Initiatives.create_initiative(stranger, %{"name" => "Elsewhere"}, agent_access: true)

      foreign = task(stranger, other, "Foreign")

      {s1, b1} =
        post_ops(ctx.owner, [
          %{
            "op" => "update",
            "type" => "task",
            "id" => foreign.id,
            "data" => %{"parent_id" => c.id}
          }
        ])

      {s2, b2} = post_ops(ctx.owner, [move_many([a1.id, foreign.id], %{"parent_id" => c.id})])

      assert s1 == 403
      assert s2 == s1
      assert [%{"error" => single}] = b1["results"]
      assert [%{"error" => many}] = b2["results"]
      assert single["code"] == "forbidden"
      assert many == single

      assert child_ids(c.id) == []
      assert Repo.get!(Task, foreign.id).parent_id == other.root_task_id
    end
  end

  describe "undo" do
    test "add history undo reverses the whole block in one step", ctx do
      %{a: a, b: b, c: c, a1: a1, a2: a2, a3: a3, b1: b1, b2: b2, b3: b3} =
        three_parents(ctx.owner, ctx.ini)

      {200, _} = post_ops(ctx.owner, [move_many([b3.id, a2.id, b1.id], %{"parent_id" => c.id})])
      assert child_ids(c.id) == [b3.id, a2.id, b1.id]

      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "add",
            "type" => "history",
            "data" => %{"initiative_id" => ctx.ini.id, "action" => "undo"}
          }
        ])

      assert status == 200
      assert [%{"status" => "ok", "data" => %{"kind" => "moved_many"}}] = body["results"]
      assert child_ids(a.id) == [a1.id, a2.id, a3.id]
      assert child_ids(b.id) == [b1.id, b2.id, b3.id]
      assert child_ids(c.id) == []
    end
  end
end
