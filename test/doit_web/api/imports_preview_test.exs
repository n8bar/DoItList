defmodule DoItWeb.Api.ImportsPreviewTest do
  @moduledoc """
  Apply a stored preview by `preview_id` — `POST /api/v1/imports` (m03.04 6.7).

  Covers: a preview returning a `preview_id` whose apply builds the same tree
  (and the same source comment) as a direct import; a target Initiative whose
  version moved since the preview refused with the standard 409 `conflict`
  carrying the current record; unknown, expired, already-applied and
  other-token ids refused with a 404 that says to preview again; a second
  preview for the same (token, target) replacing the first while a preview for
  another target survives; and the request-shape rules — `text` and
  `preview_id` together, neither, or `preview_id` with `preview: true`.

  A preview and its apply must share one token, so requests here take an
  explicit token; the per-token rate limit (5/window in `config/test.exs`)
  bounds each test to at most five requests on one token.
  """
  use DoItWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  alias DoIt.{Accounts, Initiatives, Repo, Tasks}
  alias DoIt.Imports.Preview
  alias DoIt.Initiatives.Initiative

  @source """
  # Quarterly Plan

  Everything we ship this quarter.

  1. Ship the thing
    1. Draft the spec
       Some detail about the draft.
    2. [x] Book the room
  2. Tell everyone
  """

  @other_source """
  - Rewrite the onboarding email
  - Delete the old one
  """

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

  defp post_import(token, params) do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/v1/imports", params)

    {conn.status, json_response(conn, conn.status)}
  end

  defp preview(token, params), do: post_import(token, Map.put(params, "preview", true))
  defp apply_id(token, id), do: post_import(token, %{"preview_id" => id})

  # The tree as {title, parent title, status, description} rows — the shape a
  # direct import and an apply-by-id must agree on, ids aside.
  defp shape(initiative_id) do
    tasks = Tasks.list_initiative_tasks(initiative_id)
    by_id = Map.new(tasks, &{&1.id, &1})

    tasks
    |> Enum.map(fn t ->
      parent = by_id[t.parent_id]
      {t.title, parent && parent.title, t.status, t.description}
    end)
    |> Enum.sort()
  end

  defp comment_bodies(task_id), do: task_id |> Tasks.list_comments() |> Enum.map(& &1.body)

  setup do
    owner = user("owner")
    {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Live"}, agent_access: true)
    %{owner: owner, ini: ini}
  end

  describe "preview then apply by id" do
    test "builds the same tree and source comment as a direct import", %{owner: owner} do
      token = token(owner)

      {200, previewed} =
        preview(token, %{
          "text" => @source,
          "filename" => "plan.md",
          "target" => %{"initiative_name" => "Via Preview"}
        })

      assert previewed["preview"] == true
      assert is_binary(previewed["preview_id"]) and previewed["preview_id"] != ""
      # Nothing was imported by the preview itself.
      assert Repo.get_by(Initiative, name: "Via Preview") == nil

      {200, applied} = apply_id(token, previewed["preview_id"])
      assert applied["preview"] == false
      via_id = applied["initiative"]["id"]
      assert applied["initiative"]["url"] =~ "/initiatives/#{via_id}"

      {200, direct} =
        post_import(token(owner), %{
          "text" => @source,
          "filename" => "plan.md",
          "target" => %{"initiative_name" => "Direct"}
        })

      direct_id = direct["initiative"]["id"]
      assert applied["counts"] == direct["counts"]
      assert applied["outline"] == direct["outline"]
      assert shape(via_id) == shape(direct_id)

      via = Initiatives.get_initiative(via_id)
      assert via.name == "Via Preview"
      assert via.description == Initiatives.get_initiative(direct_id).description
      # The stored filename reaches the source comment.
      assert comment_bodies(via.root_task_id) == ["Imported from plan.md"]
    end

    test "into an existing Initiative under a parent Task, ignoring a target sent alongside",
         %{owner: owner, ini: ini} do
      token = token(owner)

      {:ok, parent} =
        Tasks.create_task(owner, %{
          "initiative_id" => ini.id,
          "parent_id" => ini.root_task_id,
          "title" => "Branch"
        })

      {200, previewed} =
        preview(token, %{
          "text" => @other_source,
          "target" => %{"initiative_id" => ini.id, "parent_task_id" => parent.id}
        })

      {200, applied} =
        post_import(token, %{
          "preview_id" => previewed["preview_id"],
          "target" => %{"initiative_name" => "Ignored"}
        })

      assert applied["initiative"]["id"] == ini.id

      assert applied["target"] == %{
               "kind" => "initiative",
               "id" => ini.id,
               "parent_task_id" => parent.id
             }

      children = Tasks.ordered_child_ids(parent.id) |> Enum.map(&Tasks.get_task(&1).title)
      assert children == ["Rewrite the onboarding email", "Delete the old one"]
      assert comment_bodies(parent.id) == ["Imported from pasted text"]
    end
  end

  describe "refusals" do
    test "a target whose version moved since the preview is a 409 with the current record",
         %{owner: owner, ini: ini} do
      token = token(owner)

      {200, previewed} =
        preview(token, %{"text" => @other_source, "target" => %{"initiative_id" => ini.id}})

      {:ok, moved} = Initiatives.update_initiative(ini, %{"name" => "Renamed"})
      assert moved.version > ini.version

      {409, body} = apply_id(token, previewed["preview_id"])
      assert body["error"]["code"] == "conflict"
      assert body["error"]["message"] =~ "preview again"
      assert body["error"]["current"]["id"] == ini.id
      assert body["error"]["current"]["version"] == moved.version
      assert body["error"]["current"]["name"] == "Renamed"
      # Nothing was written.
      assert length(Tasks.list_initiative_tasks(ini.id)) == 1
    end

    test "an unknown id is a 404 that says to preview again", %{owner: owner} do
      {404, body} = apply_id(token(owner), "not-a-preview")
      assert body["error"]["status"] == 404
      assert body["error"]["message"] =~ "\"preview\": true"
    end

    test "an expired id is a 404", %{owner: owner, ini: ini} do
      token = token(owner)

      {200, previewed} =
        preview(token, %{"text" => @other_source, "target" => %{"initiative_id" => ini.id}})

      id = previewed["preview_id"]
      past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
      {1, _} = Repo.update_all(from(p in Preview, where: p.id == ^id), set: [expires_at: past])

      {404, body} = apply_id(token, id)
      assert body["error"]["message"] =~ "expired"
      assert length(Tasks.list_initiative_tasks(ini.id)) == 1
    end

    test "an already-applied id is a 404 and imports nothing more", %{owner: owner, ini: ini} do
      token = token(owner)

      {200, previewed} =
        preview(token, %{"text" => @other_source, "target" => %{"initiative_id" => ini.id}})

      {200, _} = apply_id(token, previewed["preview_id"])
      assert length(Tasks.list_initiative_tasks(ini.id)) == 3

      {404, body} = apply_id(token, previewed["preview_id"])
      assert body["error"]["message"] =~ "already applied"
      assert length(Tasks.list_initiative_tasks(ini.id)) == 3
    end

    test "another token's id is a 404, even for the same user", %{owner: owner, ini: ini} do
      {200, previewed} =
        preview(token(owner), %{
          "text" => @other_source,
          "target" => %{"initiative_id" => ini.id}
        })

      {404, _} = apply_id(token(owner), previewed["preview_id"])
      {404, _} = apply_id(token(user("stranger")), previewed["preview_id"])
      assert length(Tasks.list_initiative_tasks(ini.id)) == 1
    end
  end

  describe "one preview per token and target" do
    test "a second preview replaces the first; a preview for another target survives",
         %{owner: owner, ini: ini} do
      token = token(owner)

      {200, first} =
        preview(token, %{"text" => @other_source, "target" => %{"initiative_name" => "Fresh"}})

      {200, elsewhere} =
        preview(token, %{"text" => @other_source, "target" => %{"initiative_id" => ini.id}})

      {200, second} =
        preview(token, %{"text" => @source, "target" => %{"initiative_name" => "Fresh"}})

      assert second["preview_id"] != first["preview_id"]
      assert Repo.get(Preview, first["preview_id"]) == nil
      assert Repo.get(Preview, elsewhere["preview_id"])

      {404, _} = apply_id(token, first["preview_id"])
      {200, applied} = apply_id(token, second["preview_id"])
      assert applied["counts"]["items"] == 4
    end
  end

  describe "request shape" do
    test "text and preview_id together, neither, or preview_id with preview are 422",
         %{owner: owner} do
      token = token(owner)

      {422, both} =
        post_import(token, %{
          "text" => @other_source,
          "preview_id" => "x",
          "target" => %{"initiative_name" => "Nope"}
        })

      assert both["error"]["message"] =~ "\"preview_id\" replaces \"text\""

      {422, neither} = post_import(token, %{"target" => %{"initiative_name" => "Nope"}})
      assert neither["error"]["message"] =~ "\"text\""
      assert neither["error"]["message"] =~ "\"preview_id\""

      {422, again} = post_import(token, %{"preview_id" => "x", "preview" => true})
      assert again["error"]["message"] =~ "to preview again"
    end
  end
end
