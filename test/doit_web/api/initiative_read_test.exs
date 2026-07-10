defmodule DoItWeb.Api.InitiativeReadTest do
  @moduledoc """
  The Initiative-scoped read endpoints (m03.01 worklist 2.1/2.2/2.3):

    * `GET /api/v1/initiatives` — list of the acting user's Initiatives.
    * `GET /api/v1/initiatives/:id` — the nested tree (roll-up + index label).
    * `GET /api/v1/initiatives/:id/activity` — paginated rollup, subtree-scoped.
    * `GET /api/v1/initiatives/:id/members` — members with roles.

  Plus the authz gate: a viewer reads, a stranger is denied, an unknown id is a
  404, and a foreign task id is a 404 (no cross-Initiative leak). The per-token
  rate limit in `config/test.exs` is 5/window, so each test keeps its token's
  request count under that.
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

  defp top_task(owner, initiative, title, attrs \\ %{}) do
    {:ok, task} =
      Tasks.create_task(
        owner,
        Map.merge(
          %{
            "initiative_id" => initiative.id,
            "parent_id" => initiative.root_task_id,
            "title" => title
          },
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

  setup do
    owner = user("owner")
    editor = user("editor")
    viewer = user("viewer")
    stranger = user("stranger")

    {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Q3 Launch"})
    {:ok, ini} = Initiatives.update_initiative(ini, %{"index_style" => "numerical"})
    {:ok, _} = Initiatives.update_subtitle(ini, "ship the dashboard")
    {:ok, _} = Initiatives.add_member(ini.id, editor.id, "editor")
    {:ok, _} = Initiatives.add_member(ini.id, viewer.id, "viewer")

    # Tree: Phase 1 (branch) over two leaves at 50 / 100 → rolls up to 75; Phase 2 a leaf.
    phase1 = top_task(owner, ini, "Phase 1")
    build = top_task(owner, ini, "Build API", %{"parent_id" => phase1.id})
    docs = top_task(owner, ini, "Write docs", %{"parent_id" => phase1.id})
    phase2 = top_task(owner, ini, "Phase 2")

    {:ok, _} = Tasks.update_task(build, owner, %{"manual_progress" => 50})
    {:ok, _} = Tasks.update_task(docs, owner, %{"manual_progress" => 100})

    # A second Initiative owned by the stranger, to source a foreign task id.
    {:ok, other} = Initiatives.create_initiative(stranger, %{"name" => "Other"})
    foreign = top_task(stranger, other, "Foreign")

    %{
      owner: owner,
      editor: editor,
      viewer: viewer,
      stranger: stranger,
      ini: ini,
      phase1: phase1,
      phase2: phase2,
      foreign: foreign
    }
  end

  describe "GET /api/v1/initiatives/:id (tree read)" do
    test "returns the nested tree with roll-up progress and index labels", ctx do
      conn =
        build_conn() |> bearer(token(ctx.owner)) |> get(~p"/api/v1/initiatives/#{ctx.ini.id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == ctx.ini.id
      assert data["name"] == "Q3 Launch"
      assert data["subtitle"] == "ship the dashboard"
      assert data["role"] == "owner"
      assert data["progress_calc"] == "leaf_average"
      assert data["index_style"] == "numerical"
      assert data["root_task_id"] == ctx.ini.root_task_id

      tasks = data["tasks"]
      assert length(tasks) == 2

      phase1 = find_node(tasks, "Phase 1")
      # Nesting present.
      assert length(phase1["children"]) == 2
      assert phase1["leaf"] == false
      # A top-level task's parent is the system root (surfaced as root_task_id).
      assert phase1["parent_id"] == ctx.ini.root_task_id
      # Roll-up progress present and correct (avg of 50 and 100).
      assert phase1["progress"] == 75
      # Index label present (non-empty under the numerical style).
      assert phase1["index"] != ""
      assert phase1["index"] =~ ~r/^\d+$/

      build = find_node(tasks, "Build API")
      assert build["progress"] == 50
      assert build["manual_progress"] == 50
      assert build["leaf"] == true
      assert build["done"] == false
      assert build["parent_id"] == phase1["id"]
      # A leaf's index nests under its parent (two dotted segments).
      assert build["index"] =~ ~r/^\d+\.\d+$/
    end

    test "task nodes carry description verbatim and a live comment_count", ctx do
      # Descriptions: one set, the rest untouched (null).
      {:ok, _} = Tasks.update_task(ctx.phase1, ctx.owner, %{"description" => "how: build it"})

      # Comments on Phase 2: two live, then one tombstoned — only live rows count.
      {:ok, c1} = Tasks.add_comment(ctx.phase2, ctx.owner, "provenance: drive 3")
      {:ok, _c2} = Tasks.add_comment(ctx.phase2, ctx.owner, "second note")
      {:ok, _} = Tasks.delete_comment(c1.id, ctx.owner)

      conn =
        build_conn() |> bearer(token(ctx.owner)) |> get(~p"/api/v1/initiatives/#{ctx.ini.id}")

      assert %{"data" => data} = json_response(conn, 200)

      phase1 = find_node(data["tasks"], "Phase 1")
      phase2 = find_node(data["tasks"], "Phase 2")
      build = find_node(data["tasks"], "Build API")

      assert phase1["description"] == "how: build it"
      assert build["description"] == nil

      assert phase2["comment_count"] == 1
      assert phase1["comment_count"] == 0
      assert build["comment_count"] == 0
    end

    test "ai_knobs is surfaced verbatim in the tree envelope and the list row", ctx do
      knobs = "deploy_day: friday\nlocale: en"
      {:ok, _} = Initiatives.update_initiative(ctx.ini, %{"ai_knobs" => knobs})

      tree =
        build_conn() |> bearer(token(ctx.owner)) |> get(~p"/api/v1/initiatives/#{ctx.ini.id}")

      assert json_response(tree, 200)["data"]["ai_knobs"] == knobs

      list = build_conn() |> bearer(token(ctx.owner)) |> get(~p"/api/v1/initiatives")
      row = json_response(list, 200)["data"] |> Enum.find(&(&1["id"] == ctx.ini.id))
      assert row["ai_knobs"] == knobs
    end
  end

  describe "GET /api/v1/initiatives (list)" do
    test "lists the acting user's Initiatives with role and top-level progress", ctx do
      conn = build_conn() |> bearer(token(ctx.owner)) |> get(~p"/api/v1/initiatives")

      assert %{"data" => list} = json_response(conn, 200)
      row = Enum.find(list, &(&1["id"] == ctx.ini.id))
      assert row["name"] == "Q3 Launch"
      assert row["role"] == "owner"
      assert is_integer(row["progress"])
    end

    test "does not leak Initiatives the user isn't a member of", ctx do
      conn = build_conn() |> bearer(token(ctx.stranger)) |> get(~p"/api/v1/initiatives")

      assert %{"data" => list} = json_response(conn, 200)
      refute Enum.any?(list, &(&1["id"] == ctx.ini.id))
    end

    test "a blank subtitle reads as \"\" in the list, matching the tree", _ctx do
      solo = user("solo")
      {:ok, blank} = Initiatives.create_initiative(solo, %{"name" => "No Subtitle"})
      tok = token(solo)

      list = build_conn() |> bearer(tok) |> get(~p"/api/v1/initiatives")
      assert %{"data" => rows} = json_response(list, 200)
      row = Enum.find(rows, &(&1["id"] == blank.id))
      # Not the stored sentinel single space, and identical to the tree path.
      assert row["subtitle"] == ""

      tree = build_conn() |> bearer(tok) |> get(~p"/api/v1/initiatives/#{blank.id}")
      assert json_response(tree, 200)["data"]["subtitle"] == ""
    end
  end

  describe "GET /api/v1/initiatives/:id/activity (rollup)" do
    test "scopes to the subtree and paginates", ctx do
      tok = token(ctx.owner)

      # Whole-Initiative rollup includes Phase 2's create event.
      full =
        build_conn()
        |> bearer(tok)
        |> get(~p"/api/v1/initiatives/#{ctx.ini.id}/activity?limit=200")

      assert %{"data" => all_events, "meta" => meta} = json_response(full, 200)
      assert meta["scope"]["task_id"] == nil
      assert Enum.any?(all_events, &(&1["task_id"] == ctx.phase2.id))

      # Subtree rollup for Phase 1 excludes Phase 2 entirely.
      sub =
        build_conn()
        |> bearer(tok)
        |> get(~p"/api/v1/initiatives/#{ctx.ini.id}/activity?task_id=#{ctx.phase1.id}&limit=200")

      assert %{"data" => sub_events, "meta" => sub_meta} = json_response(sub, 200)
      assert sub_meta["scope"]["task_id"] == ctx.phase1.id
      subtree = MapSet.new(Tasks.subtree_ids(ctx.phase1.id))
      assert Enum.all?(sub_events, &MapSet.member?(subtree, &1["task_id"]))
      refute Enum.any?(sub_events, &(&1["task_id"] == ctx.phase2.id))

      # Pagination: a small page reports has_more + the next offset.
      page =
        build_conn() |> bearer(tok) |> get(~p"/api/v1/initiatives/#{ctx.ini.id}/activity?limit=2")

      assert %{"data" => events, "meta" => page_meta} = json_response(page, 200)
      assert length(events) == 2
      assert page_meta["limit"] == 2
      assert page_meta["has_more"] == true
      assert page_meta["next_offset"] == 2
    end
  end

  describe "GET /api/v1/initiatives/:id/members" do
    test "returns the members with their roles", ctx do
      conn =
        build_conn()
        |> bearer(token(ctx.owner))
        |> get(~p"/api/v1/initiatives/#{ctx.ini.id}/members")

      assert %{"data" => members} = json_response(conn, 200)
      assert length(members) == 3
      roles = Map.new(members, &{&1["user_id"], &1["role"]})
      assert roles[ctx.owner.id] == "owner"
      assert roles[ctx.editor.id] == "editor"
      assert roles[ctx.viewer.id] == "viewer"
      assert Enum.all?(members, &is_binary(&1["name"]))
    end
  end

  describe "authorization" do
    test "a viewer-role token can read the tree", ctx do
      conn =
        build_conn() |> bearer(token(ctx.viewer)) |> get(~p"/api/v1/initiatives/#{ctx.ini.id}")

      assert json_response(conn, 200)["data"]["role"] == "viewer"
    end

    test "a stranger is forbidden (403) on every read endpoint", ctx do
      tok = token(ctx.stranger)
      id = ctx.ini.id

      assert resp(build_conn() |> bearer(tok) |> get(~p"/api/v1/initiatives/#{id}"), 403)
      assert resp(build_conn() |> bearer(tok) |> get(~p"/api/v1/initiatives/#{id}/activity"), 403)
      assert resp(build_conn() |> bearer(tok) |> get(~p"/api/v1/initiatives/#{id}/members"), 403)
    end

    test "an unknown or garbage Initiative id is a 404", ctx do
      tok = token(ctx.owner)
      assert resp(build_conn() |> bearer(tok) |> get(~p"/api/v1/initiatives/99999999"), 404)
      assert resp(build_conn() |> bearer(tok) |> get(~p"/api/v1/initiatives/not-an-id"), 404)
    end

    test "a foreign task id on the activity rollup is a 404", ctx do
      conn =
        build_conn()
        |> bearer(token(ctx.owner))
        |> get(~p"/api/v1/initiatives/#{ctx.ini.id}/activity?task_id=#{ctx.foreign.id}")

      assert resp(conn, 404)
    end
  end

  defp resp(conn, status) do
    assert %{"error" => %{"status" => ^status}} = json_response(conn, status)
    true
  end
end
