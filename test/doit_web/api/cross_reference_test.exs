defmodule DoItWeb.Api.CrossReferenceTest do
  @moduledoc """
  Task->task cross-references (m03.01 worklist 4) — created/removed over the
  atomic `POST /api/v1/operations` endpoint (worklist 3) and surfaced in the
  whole-tree read (worklist 2).

  Covers: create via a single `add link` op and via batch-local `*_lid`; the
  reference surfaces with the target's LIVE index label (and the incoming
  `referenced_by` side); the SAME link renders the target's NEW label after a
  reorder AND a reparent (stable-id anchoring + live-label render); remove;
  dedupe (twice, and inside one batch); authz (viewer/stranger can't write,
  cross-Initiative target rejected, nothing persisted); the soft-deleted-endpoint
  policy (hidden from reads but the row persists and reappears on restore;
  creating a link to a Trashed task is a per-op error).

  Each HTTP helper mints a FRESH token, so the per-token rate limit (5/window in
  `config/test.exs`) never bites across a test's several calls.
  """
  use DoItWeb.ConnCase, async: true

  alias DoIt.{Accounts, Initiatives, Tasks}
  alias DoIt.Repo
  alias DoIt.Tasks.TaskLink

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

  # POST a batch as `user` (fresh token) — returns {status, decoded_body}.
  defp post_ops(user, operations) do
    conn =
      build_conn()
      |> bearer(token(user))
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/v1/operations", %{"operations" => operations})

    {conn.status, json_response(conn, conn.status)}
  end

  # GET the whole tree as `user` (fresh token) — returns the "data" payload.
  defp get_tree(user, ini) do
    conn =
      build_conn()
      |> bearer(token(user))
      |> get(~p"/api/v1/initiatives/#{ini.id}")

    json_response(conn, 200)["data"]
  end

  defp top_task(owner, ini, title, attrs \\ %{}) do
    {:ok, task} =
      Tasks.create_task(
        owner,
        Map.merge(
          %{"initiative_id" => ini.id, "parent_id" => ini.root_task_id, "title" => title},
          attrs
        )
      )

    task
  end

  defp find_node(nodes, title) do
    Enum.find_value(nodes, fn node ->
      cond do
        node["title"] == title -> node
        true -> find_node(node["children"] || [], title)
      end
    end)
  end

  defp link_count, do: Repo.aggregate(TaskLink, :count)

  setup do
    owner = user("owner")
    editor = user("editor")
    viewer = user("viewer")
    stranger = user("stranger")

    {:ok, ini} =
      Initiatives.create_initiative(owner, %{"name" => "Q3 Launch", "index_style" => "numerical"})

    {:ok, _} = Initiatives.add_member(ini.id, editor.id, "editor")
    {:ok, _} = Initiatives.add_member(ini.id, viewer.id, "viewer")

    %{owner: owner, editor: editor, viewer: viewer, stranger: stranger, ini: ini}
  end

  describe "creating a cross-reference via the atomic endpoint" do
    test "a single add link op links two tasks and surfaces in the tree with the target's live label",
         %{owner: owner, ini: ini} do
      a = top_task(owner, ini, "A")
      b = top_task(owner, ini, "B")

      {status, body} =
        post_ops(owner, [
          %{
            "op" => "add",
            "type" => "link",
            "data" => %{"source_id" => a.id, "target_id" => b.id}
          }
        ])

      assert status == 200
      assert [%{"status" => "ok", "data" => data}] = body["results"]
      assert data["type"] == "link"
      assert data["source_task_id"] == a.id
      assert data["target_task_id"] == b.id

      tree = get_tree(owner, ini)
      node_a = find_node(tree["tasks"], "A")
      node_b = find_node(tree["tasks"], "B")

      # A's OUTGOING reference resolves to B's current index label ("2") + title.
      assert node_a["cross_references"] == [
               %{"target_id" => b.id, "target_index" => "2", "target_title" => "B"}
             ]

      # And B carries the INCOMING side back to A ("1").
      assert node_b["referenced_by"] == [
               %{"source_id" => a.id, "source_index" => "1", "source_title" => "A"}
             ]

      # B references nothing outgoing; A is referenced by nothing.
      assert node_b["cross_references"] == []
      assert node_a["referenced_by"] == []
    end

    test "a batch creates two tasks via lid and links them in the same request", %{
      owner: owner,
      ini: ini
    } do
      {status, body} =
        post_ops(owner, [
          %{
            "op" => "add",
            "type" => "task",
            "lid" => "t1",
            "data" => %{"parent_id" => ini.root_task_id, "title" => "First"}
          },
          %{
            "op" => "add",
            "type" => "task",
            "lid" => "t2",
            "data" => %{"parent_id" => ini.root_task_id, "title" => "Second"}
          },
          %{
            "op" => "add",
            "type" => "link",
            "data" => %{"source_lid" => "t1", "target_lid" => "t2"}
          }
        ])

      assert status == 200
      assert [_t1, t2, link] = body["results"]
      assert Enum.all?(body["results"], &(&1["status"] == "ok"))
      assert link["data"]["type"] == "link"
      assert link["data"]["target_task_id"] == t2["data"]["id"]

      tree = get_tree(owner, ini)
      node_first = find_node(tree["tasks"], "First")

      assert node_first["cross_references"] == [
               %{
                 "target_id" => t2["data"]["id"],
                 "target_index" => "2",
                 "target_title" => "Second"
               }
             ]
    end
  end

  describe "stable-id anchoring + live-label render" do
    test "the SAME link renders the target's NEW index label after a reorder and a reparent",
         %{owner: owner, ini: ini} do
      a = top_task(owner, ini, "A")
      _b = top_task(owner, ini, "B")
      c = top_task(owner, ini, "C")

      # Link A -> C through the endpoint. C is third top-level: index "3".
      {200, _} =
        post_ops(owner, [
          %{
            "op" => "add",
            "type" => "link",
            "data" => %{"source_id" => a.id, "target_id" => c.id}
          }
        ])

      tree = get_tree(owner, ini)

      assert [%{"target_index" => "3"}] = find_node(tree["tasks"], "A")["cross_references"]

      # Reorder C to the front (position 0): order becomes C, A, B — C is now "1".
      {:ok, _} = Tasks.move_task(c, owner, %{"parent_id" => ini.root_task_id, "position" => 0})

      tree = get_tree(owner, ini)

      assert [%{"target_id" => target_id, "target_index" => "1"}] =
               find_node(tree["tasks"], "A")["cross_references"]

      assert target_id == c.id

      # Reparent C under A: C becomes A's only child — index "1.1".
      {:ok, _} = Tasks.move_task(c, owner, %{"parent_id" => a.id})

      tree = get_tree(owner, ini)

      assert [%{"target_id" => ^target_id, "target_index" => "1.1"}] =
               find_node(tree["tasks"], "A")["cross_references"]

      # The whole sequence touched ONE link row — anchored on the id, never recreated.
      assert link_count() == 1
    end
  end

  describe "removing a cross-reference via the atomic endpoint" do
    test "a remove link op deletes the link; the reference disappears from the tree", %{
      owner: owner,
      ini: ini
    } do
      a = top_task(owner, ini, "A")
      b = top_task(owner, ini, "B")
      {:ok, _} = Tasks.create_link(a, b)

      assert link_count() == 1

      {status, body} =
        post_ops(owner, [
          %{
            "op" => "remove",
            "type" => "link",
            "data" => %{"source_id" => a.id, "target_id" => b.id}
          }
        ])

      assert status == 200
      assert [%{"status" => "ok", "data" => %{"removed" => true}}] = body["results"]
      assert link_count() == 0

      tree = get_tree(owner, ini)
      assert find_node(tree["tasks"], "A")["cross_references"] == []
    end

    test "removing a link that doesn't exist is a clean not_found per-op error", %{
      owner: owner,
      ini: ini
    } do
      a = top_task(owner, ini, "A")
      b = top_task(owner, ini, "B")

      {status, body} =
        post_ops(owner, [
          %{
            "op" => "remove",
            "type" => "link",
            "data" => %{"source_id" => a.id, "target_id" => b.id}
          }
        ])

      assert status == 422
      assert [%{"status" => "error", "error" => %{"code" => "not_found"}}] = body["results"]
    end
  end

  describe "dedupe (unique source/target)" do
    test "creating the same link twice is rejected; only one persists", %{owner: owner, ini: ini} do
      a = top_task(owner, ini, "A")
      b = top_task(owner, ini, "B")

      op = %{
        "op" => "add",
        "type" => "link",
        "data" => %{"source_id" => a.id, "target_id" => b.id}
      }

      assert {200, _} = post_ops(owner, [op])
      assert {422, body} = post_ops(owner, [op])

      assert [%{"status" => "error", "error" => %{"code" => "unprocessable_entity"}}] =
               body["results"]

      assert link_count() == 1
    end

    test "a duplicate link inside one batch rolls the whole batch back", %{owner: owner, ini: ini} do
      a = top_task(owner, ini, "A")
      b = top_task(owner, ini, "B")

      op = %{
        "op" => "add",
        "type" => "link",
        "data" => %{"source_id" => a.id, "target_id" => b.id}
      }

      assert {422, body} = post_ops(owner, [op, op])
      assert [%{"status" => "not_applied"}, %{"status" => "error"}] = body["results"]
      # All-or-nothing: the first (valid) add was rolled back with the duplicate.
      assert link_count() == 0
    end
  end

  describe "authorization (edit on the source's Initiative)" do
    test "a viewer cannot create a link — 403, nothing persisted", %{
      owner: owner,
      viewer: viewer,
      ini: ini
    } do
      a = top_task(owner, ini, "A")
      b = top_task(owner, ini, "B")

      {status, body} =
        post_ops(viewer, [
          %{
            "op" => "add",
            "type" => "link",
            "data" => %{"source_id" => a.id, "target_id" => b.id}
          }
        ])

      assert status == 403
      assert [%{"status" => "error", "error" => %{"code" => "forbidden"}}] = body["results"]
      assert link_count() == 0
    end

    test "a viewer cannot remove a link — 403, the link survives", %{
      owner: owner,
      viewer: viewer,
      ini: ini
    } do
      a = top_task(owner, ini, "A")
      b = top_task(owner, ini, "B")
      {:ok, _} = Tasks.create_link(a, b)

      {status, _body} =
        post_ops(viewer, [
          %{
            "op" => "remove",
            "type" => "link",
            "data" => %{"source_id" => a.id, "target_id" => b.id}
          }
        ])

      assert status == 403
      assert link_count() == 1
    end

    test "a stranger (non-member) cannot create a link — 403", %{
      owner: owner,
      stranger: stranger,
      ini: ini
    } do
      a = top_task(owner, ini, "A")
      b = top_task(owner, ini, "B")

      {status, _body} =
        post_ops(stranger, [
          %{
            "op" => "add",
            "type" => "link",
            "data" => %{"source_id" => a.id, "target_id" => b.id}
          }
        ])

      assert status == 403
      assert link_count() == 0
    end

    test "a cross-Initiative / foreign target is rejected — 422, nothing persisted", %{
      owner: owner,
      ini: ini
    } do
      a = top_task(owner, ini, "A")

      {:ok, other} = Initiatives.create_initiative(owner, %{"name" => "Other"})
      foreign = top_task(owner, other, "Foreign")

      {status, body} =
        post_ops(owner, [
          %{
            "op" => "add",
            "type" => "link",
            "data" => %{"source_id" => a.id, "target_id" => foreign.id}
          }
        ])

      assert status == 422

      assert [
               %{
                 "status" => "error",
                 "error" => %{"code" => "unprocessable_entity", "pointer" => "target_id"}
               }
             ] =
               body["results"]

      assert link_count() == 0
    end
  end

  describe "soft-deleted endpoint policy" do
    test "a link to a soft-deleted task is hidden from reads, persists, and reappears on restore",
         %{owner: owner, ini: ini} do
      a = top_task(owner, ini, "A")
      b = top_task(owner, ini, "B")
      {:ok, _} = Tasks.create_link(a, b)

      assert [%{"target_index" => "2"}] =
               find_node(get_tree(owner, ini)["tasks"], "A")["cross_references"]

      # Trash B (soft delete): the reference is hidden, but the link row survives.
      {:ok, _} = Tasks.delete_task(b, owner)

      assert find_node(get_tree(owner, ini)["tasks"], "A")["cross_references"] == []
      assert link_count() == 1

      # Restore B: the same link reappears, rendering B's live label again.
      {:ok, _} = Tasks.restore_tasks([b.id], ini.root_task_id, ini.id)

      assert [%{"target_id" => target_id, "target_index" => "2"}] =
               find_node(get_tree(owner, ini)["tasks"], "A")["cross_references"]

      assert target_id == b.id
    end

    test "creating a link to a soft-deleted task is a not_found per-op error", %{
      owner: owner,
      ini: ini
    } do
      a = top_task(owner, ini, "A")
      b = top_task(owner, ini, "B")
      {:ok, _} = Tasks.delete_task(b, owner)

      {status, body} =
        post_ops(owner, [
          %{
            "op" => "add",
            "type" => "link",
            "data" => %{"source_id" => a.id, "target_id" => b.id}
          }
        ])

      assert status == 422
      assert [%{"status" => "error", "error" => %{"code" => "not_found"}}] = body["results"]
      assert link_count() == 0
    end
  end
end
