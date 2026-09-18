defmodule DoItWeb.Api.OperationsSortTest do
  @moduledoc """
  `update task` with `sort_mode` / `sort_reverse` / `cascade_sort` (m04.02
  item 5.1.5) — the branch's sort through `Tasks.set_sort/4` and the subtree's
  inheritance through `Tasks.cascade_sort/2`, as one op.

  Covers: setting a mode re-sorts the children; `sort_reverse` alone keeps the
  mode; `sort_mode: null` inherits; a cascade makes every descendant branch
  inherit and lists them in `records`; set and cascade in one op; a viewer is
  refused; an unknown mode, a non-boolean flag, and a sort mixed with another
  concern are per-op errors.

  Each `post_ops` mints a fresh token, so the per-token rate limit never bites.
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

  defp post_ops(user, operations) do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token(user))
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/v1/operations", %{"operations" => operations})

    {conn.status, json_response(conn, conn.status)}
  end

  defp task(actor, ini, title, parent_id \\ nil) do
    {:ok, task} =
      Tasks.create_task(actor, %{
        "initiative_id" => ini.id,
        "parent_id" => parent_id || ini.root_task_id,
        "title" => title
      })

    task
  end

  defp sort_op(id, data), do: %{"op" => "update", "type" => "task", "id" => id, "data" => data}

  defp child_ids(parent_id), do: Tasks.ordered_child_ids(parent_id)

  # A branch with three children created out of alphabetical order, holding a
  # grandchild branch with two children of its own.
  defp branch(owner, ini) do
    parent = task(owner, ini, "Parent")
    c = task(owner, ini, "Cherry", parent.id)
    a = task(owner, ini, "Apple", parent.id)
    b = task(owner, ini, "Banana", parent.id)
    inner = task(owner, ini, "Zeta inner", b.id)
    z = task(owner, ini, "Zucchini", inner.id)
    y = task(owner, ini, "Yam", inner.id)
    %{parent: parent, a: a, b: b, c: c, inner: inner, y: y, z: z}
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

  describe "set sort" do
    test "sort_mode re-sorts the children and the record carries the new pair", ctx do
      %{parent: parent, a: a, b: b, c: c} = branch(ctx.owner, ctx.ini)

      {status, body} = post_ops(ctx.editor, [sort_op(parent.id, %{"sort_mode" => "alphabetical"})])

      assert status == 200
      assert [%{"status" => "ok", "data" => data}] = body["results"]
      assert data["id"] == parent.id

      assert [%{"id" => id, "sort_mode" => "alphabetical", "sort_reverse" => false}] =
               data["records"]

      assert id == parent.id
      assert child_ids(parent.id) == [a.id, b.id, c.id]
    end

    test "sort_reverse alone keeps the mode and flips the order", ctx do
      %{parent: parent, a: a, b: b, c: c} = branch(ctx.owner, ctx.ini)
      {:ok, _} = Tasks.set_sort(parent, ctx.owner, "alphabetical", false)

      {status, body} = post_ops(ctx.owner, [sort_op(parent.id, %{"sort_reverse" => true})])

      assert status == 200
      assert [%{"data" => %{"records" => [record]}}] = body["results"]
      assert record["sort_mode"] == "alphabetical"
      assert record["sort_reverse"] == true
      assert child_ids(parent.id) == [c.id, b.id, a.id]
    end

    test "sort_mode null inherits and re-sorts by the ancestor's mode", ctx do
      %{parent: parent, b: b, inner: inner, y: y, z: z} = branch(ctx.owner, ctx.ini)
      {:ok, _} = Tasks.set_sort(parent, ctx.owner, "alphabetical", false)
      {:ok, _} = Tasks.set_sort(Tasks.get_task!(inner.id), ctx.owner, "manual", false)
      assert child_ids(inner.id) == [z.id, y.id]

      {status, body} = post_ops(ctx.owner, [sort_op(inner.id, %{"sort_mode" => nil})])

      assert status == 200
      assert [%{"data" => %{"records" => [record]}}] = body["results"]
      assert record["sort_mode"] == nil
      assert Tasks.get_task!(inner.id).sort_mode == nil
      assert Tasks.get_task!(b.id).sort_mode == nil
      assert child_ids(inner.id) == [y.id, z.id]
    end
  end

  describe "cascade" do
    test "cascade_sort makes every descendant branch inherit and lists them", ctx do
      %{parent: parent, b: b, inner: inner, y: y, z: z} = branch(ctx.owner, ctx.ini)
      {:ok, _} = Tasks.set_sort(parent, ctx.owner, "alphabetical", false)
      {:ok, _} = Tasks.set_sort(Tasks.get_task!(b.id), ctx.owner, "priority", true)
      {:ok, _} = Tasks.set_sort(Tasks.get_task!(inner.id), ctx.owner, "manual", false)

      {status, body} = post_ops(ctx.editor, [sort_op(parent.id, %{"cascade_sort" => true})])

      assert status == 200
      assert [%{"status" => "ok", "data" => data}] = body["results"]
      ids = Enum.map(data["records"], & &1["id"])
      assert ids == Enum.sort([parent.id, b.id, inner.id])

      assert Enum.all?(data["records"], &(&1["sort_mode"] == nil or &1["id"] == parent.id))
      assert Tasks.get_task!(b.id).sort_mode == nil
      assert Tasks.get_task!(inner.id).sort_mode == nil
      assert Tasks.get_task!(parent.id).sort_mode == "alphabetical"
      assert child_ids(inner.id) == [y.id, z.id]
    end

    test "set and cascade in one op sets first, then cascades", ctx do
      %{parent: parent, a: a, b: b, c: c, inner: inner, y: y, z: z} = branch(ctx.owner, ctx.ini)
      {:ok, _} = Tasks.set_sort(Tasks.get_task!(inner.id), ctx.owner, "manual", false)

      {status, body} =
        post_ops(ctx.owner, [
          sort_op(parent.id, %{
            "sort_mode" => "alphabetical",
            "sort_reverse" => true,
            "cascade_sort" => true
          })
        ])

      assert status == 200
      assert [%{"data" => %{"records" => records}}] = body["results"]
      assert length(records) == 3
      parent_record = Enum.find(records, &(&1["id"] == parent.id))
      assert parent_record["sort_mode"] == "alphabetical"
      assert parent_record["sort_reverse"] == true
      assert child_ids(parent.id) == [c.id, b.id, a.id]
      assert child_ids(inner.id) == [z.id, y.id]
    end
  end

  describe "rejections" do
    test "a viewer is refused and nothing changes", ctx do
      %{parent: parent, c: c, a: a, b: b} = branch(ctx.owner, ctx.ini)

      {status, body} = post_ops(ctx.viewer, [sort_op(parent.id, %{"sort_mode" => "alphabetical"})])

      assert status == 403
      assert [%{"status" => "error", "error" => %{"code" => "forbidden"}}] = body["results"]
      assert child_ids(parent.id) == [c.id, a.id, b.id]
      assert Tasks.get_task!(parent.id).sort_mode == nil
    end

    test "an unknown mode is a 422 pointing at sort_mode", ctx do
      %{parent: parent} = branch(ctx.owner, ctx.ini)

      {status, body} = post_ops(ctx.owner, [sort_op(parent.id, %{"sort_mode" => "random"})])

      assert status == 422

      assert [%{"error" => %{"code" => "unprocessable_entity", "pointer" => "sort_mode"}}] =
               body["results"]

      assert Tasks.get_task!(parent.id).sort_mode == nil
    end

    test "a non-boolean flag is a 422 pointing at the flag", ctx do
      %{parent: parent} = branch(ctx.owner, ctx.ini)

      {status, body} = post_ops(ctx.owner, [sort_op(parent.id, %{"cascade_sort" => "yes"})])

      assert status == 422
      assert [%{"error" => %{"pointer" => "cascade_sort"}}] = body["results"]
    end

    test "a sort mixed with a field edit is one concern too many", ctx do
      %{parent: parent} = branch(ctx.owner, ctx.ini)

      {status, body} =
        post_ops(ctx.owner, [
          sort_op(parent.id, %{"sort_mode" => "alphabetical", "title" => "Renamed"})
        ])

      assert status == 422
      assert [%{"error" => %{"code" => "unprocessable_entity"}}] = body["results"]
      assert Tasks.get_task!(parent.id).title == "Parent"
    end
  end
end
