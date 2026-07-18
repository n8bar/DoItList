defmodule DoItWeb.InitiativeWorkspaceRefFieldsTest do
  @moduledoc """
  Server seams of the `%`-reference O&C fixes (m03.03 items 4.7–4.9):

    * ONE toast per task save carrying both facts — "Saved — linked <label> —
      <title>" when the save's resolved ref set changed, plain "Saved." when it
      didn't (4.8). The ref diff is per-field, so a description ref announces
      even when the title already references the same task.
    * `_target` scoping — a phx-change flush serializes the whole form, where
      sibling `%`-ref fields hold the rehydrated `%label` (not the stored
      `%<id>` token); an unscoped apply would re-save those labels literally,
      destroying the stored reference (4.7/4.9 root cause). A change-event save
      applies ONLY the `_target` field; a submit (no `_target`) applies the
      full form (the client tokenizes it before serialization — JS, so that
      half is [Human]-verified).
    * The initiative header renders both ref surfaces with their render
      markers (`data-initiative-subtitle-body` / `data-initiative-description-body`)
      so the client renderer resolves tokens to live links (4.9).

  The RefField box lifecycle itself (rehydrate on mount / patch / re-number)
  is client JS with no automated harness — [Human]-verified (doc item 4.7.5).
  """
  use DoItWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

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

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, user.id)
  end

  defp new_task(owner, ini, attrs) do
    {:ok, t} =
      Tasks.create_task(
        owner,
        attrs
        |> Map.put("initiative_id", ini.id)
        |> Map.put_new("parent_id", ini.root_task_id)
      )

    t
  end

  setup %{conn: conn} do
    owner = user("owner")
    {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Alpha"})
    # Numbered labels so the "linked" flash carries a real number.
    {:ok, ini} = Initiatives.update_initiative(ini, %{"index_style" => "numerical"})
    # Position 0 root child => numerical label "1".
    target = new_task(owner, ini, %{"title" => "Target"})
    source = new_task(owner, ini, %{"title" => "Source"})

    %{conn: log_in(conn, owner), owner: owner, ini: ini, target: target, source: source}
  end

  describe "update_task flash (4.8) — one toast, both facts" do
    test "a save that adds a ref flashes Saved — linked <label> — <title>",
         %{conn: conn, ini: ini, target: target, source: source} do
      {:ok, view, _html} = live(conn, ~p"/initiatives/#{ini.id}")

      html =
        render_hook(view, "update_task", %{
          "task" => %{"description" => "see %<#{target.id}>"},
          "id" => to_string(source.id)
        })

      assert html =~ "Saved — linked 1 — Target"
    end

    test "a description ref announces even when the title already holds the same ref",
         %{conn: conn, owner: owner, ini: ini, target: target} do
      source = new_task(owner, ini, %{"title" => "Holds %<#{target.id}> already"})
      {:ok, view, _html} = live(conn, ~p"/initiatives/#{ini.id}")

      html =
        render_hook(view, "update_task", %{
          "task" => %{"description" => "now also %<#{target.id}>"},
          "id" => to_string(source.id)
        })

      assert html =~ "Saved — linked 1 — Target"
    end

    test "a save with an unchanged ref set flashes plain Saved.",
         %{conn: conn, owner: owner, ini: ini, target: target} do
      source = new_task(owner, ini, %{"title" => "T", "description" => "see %<#{target.id}>"})
      {:ok, view, _html} = live(conn, ~p"/initiatives/#{ini.id}")

      html =
        render_hook(view, "update_task", %{
          "task" => %{"description" => "reworded, see %<#{target.id}>"},
          "id" => to_string(source.id)
        })

      assert html =~ "Saved."
      refute html =~ "Saved — linked"
    end
  end

  describe "update_task _target scoping (4.7) — sibling ref fields survive" do
    test "a priority change never re-saves the title's displayed label form",
         %{conn: conn, owner: owner, ini: ini, target: target} do
      source = new_task(owner, ini, %{"title" => "Holds %<#{target.id}> ref"})
      {:ok, view, _html} = live(conn, ~p"/initiatives/#{ini.id}")

      render_hook(view, "update_task", %{
        "task" => %{"title" => "Holds %1 ref", "priority" => "high"},
        "id" => to_string(source.id),
        "_target" => ["task", "priority"]
      })

      reloaded = Tasks.get_task(source.id)
      assert reloaded.priority == "high"
      # The stored token survives — the label-form sibling value was dropped.
      assert reloaded.title == "Holds %<#{target.id}> ref"
    end

    test "a submit (no _target) still applies the full form",
         %{conn: conn, owner: owner, ini: ini, target: target} do
      source = new_task(owner, ini, %{"title" => "Holds %<#{target.id}> ref"})
      {:ok, view, _html} = live(conn, ~p"/initiatives/#{ini.id}")

      render_hook(view, "update_task", %{
        "task" => %{"title" => "Retitled %<#{target.id}>", "priority" => "low"},
        "id" => to_string(source.id)
      })

      reloaded = Tasks.get_task(source.id)
      assert reloaded.priority == "low"
      assert reloaded.title == "Retitled %<#{target.id}>"
    end
  end

  describe "update_initiative _target scoping (4.9) — description token survives" do
    test "a name change never re-saves the description's displayed label form",
         %{conn: conn, ini: ini, target: target} do
      {:ok, _} = Initiatives.update_initiative(ini, %{"description" => "see %<#{target.id}>"})
      {:ok, view, _html} = live(conn, ~p"/initiatives/#{ini.id}")

      render_hook(view, "update_initiative", %{
        "initiative" => %{"name" => "Renamed", "description" => "see %1"},
        "_target" => ["initiative", "name"]
      })

      reloaded = Initiatives.get_initiative!(ini.id)
      assert reloaded.name == "Renamed"
      # The stored token survives — the label-form sibling value was dropped.
      assert reloaded.description == "see %<#{target.id}>"
    end

    test "a description save that adds a ref keeps its standalone Linked flash",
         %{conn: conn, ini: ini, target: target} do
      {:ok, view, _html} = live(conn, ~p"/initiatives/#{ini.id}")

      html =
        render_hook(view, "update_initiative", %{
          "initiative" => %{"description" => "see %<#{target.id}>"},
          "_target" => ["initiative", "description"]
        })

      assert html =~ "Linked 1 — Target"
    end
  end

  describe "initiative header render markers (4.9)" do
    test "subtitle and description surfaces both carry their render markers",
         %{conn: conn, ini: ini, target: target} do
      {:ok, _} = Initiatives.update_subtitle(ini, "sub %<#{target.id}>")
      {:ok, _} = Initiatives.update_initiative(ini, %{"description" => "desc %<#{target.id}>"})

      {:ok, view, _html} = live(conn, ~p"/initiatives/#{ini.id}")

      assert has_element?(view, "p[data-initiative-subtitle-body]")
      assert has_element?(view, "p[data-initiative-description-body]")
    end
  end
end
