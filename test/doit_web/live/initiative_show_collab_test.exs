defmodule DoItWeb.InitiativeShowCollabTest do
  @moduledoc """
  Live collaboration (m02.08 worklist 3): the ephemeral per-Initiative chat
  (item 3.1) and the comment edit/delete lifecycle UI (item 3.2). Chat's
  end-to-end real-time path is presence/PubSub — verified [Human] in-browser;
  here we cover what's drivable server-side: messages fan out to viewers and
  are not persisted, and the author-only comment controls + tombstone render.
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
    %{conn: conn, owner: owner, ini: ini}
  end

  describe "live chat (item 3.1)" do
    test "the chat overlay renders for a viewer", %{conn: conn, owner: owner, ini: ini} do
      {:ok, view, _html} = live(log_in(conn, owner), ~p"/initiatives/#{ini.id}")
      assert has_element?(view, "#initiative-chat")
      assert has_element?(view, "[data-chat-input]")
    end

    test "a sent message fans out to another viewer (and never persists)", %{
      conn: conn,
      owner: owner,
      ini: ini
    } do
      member = user("mate")
      {:ok, _} = Initiatives.add_member(ini.id, member.id, "editor")

      {:ok, owner_view, _} = live(log_in(conn, owner), ~p"/initiatives/#{ini.id}")
      {:ok, mate_view, _} = live(log_in(build_conn(), member), ~p"/initiatives/#{ini.id}")

      # The colocated hook intercepts the form submit and pushes send_chat —
      # simulate that pushEvent directly.
      render_hook(owner_view, "send_chat", %{"body" => "hello viewers"})

      # Both the sender and the other live viewer see it.
      assert render(owner_view) =~ "hello viewers"
      assert render(mate_view) =~ "hello viewers"

      # Nothing was written: a brand-new viewer mounts to an empty log.
      {:ok, fresh_view, _} = live(log_in(build_conn(), member), ~p"/initiatives/#{ini.id}")
      refute render(fresh_view) =~ "hello viewers"
    end

    test "a blank message is dropped", %{conn: conn, owner: owner, ini: ini} do
      {:ok, view, _} = live(log_in(conn, owner), ~p"/initiatives/#{ini.id}")
      render_hook(view, "send_chat", %{"body" => "   "})
      refute has_element?(view, "[id^='chat-msg-']")
    end
  end

  describe "comment lifecycle UI (item 3.2)" do
    test "the author sees edit/delete controls; a non-author does not", %{
      conn: conn,
      owner: owner,
      ini: ini
    } do
      member = user("mate")
      {:ok, _} = Initiatives.add_member(ini.id, member.id, "editor")
      task = new_task(owner, ini, %{"title" => "T"})
      {:ok, comment} = Tasks.add_comment(task, owner, "owner says hi")

      {:ok, owner_view, _} = live(log_in(conn, owner), ~p"/initiatives/#{ini.id}")
      render_hook(owner_view, "select_task", %{"id" => to_string(task.id)})
      assert has_element?(owner_view, "#edit-comment-btn-#{comment.id}")
      assert has_element?(owner_view, "#delete-comment-btn-#{comment.id}")

      {:ok, mate_view, _} = live(log_in(build_conn(), member), ~p"/initiatives/#{ini.id}")
      render_hook(mate_view, "select_task", %{"id" => to_string(task.id)})
      refute has_element?(mate_view, "#edit-comment-btn-#{comment.id}")
      refute has_element?(mate_view, "#delete-comment-btn-#{comment.id}")
    end

    test "deleting one's own comment leaves a tombstone in the pane", %{
      conn: conn,
      owner: owner,
      ini: ini
    } do
      task = new_task(owner, ini, %{"title" => "T"})
      {:ok, comment} = Tasks.add_comment(task, owner, "delete me")

      {:ok, view, _} = live(log_in(conn, owner), ~p"/initiatives/#{ini.id}")
      render_hook(view, "select_task", %{"id" => to_string(task.id)})

      view |> element("#delete-comment-btn-#{comment.id}") |> render_click()

      html = render(view)
      assert html =~ "comment deleted"
      refute html =~ "delete me"
      # The tombstone row survives — thread shape holds.
      assert has_element?(view, "#comment-#{comment.id}")
    end

    test "the edit-history popup renders statically with the prior versions", %{
      conn: conn,
      owner: owner,
      ini: ini
    } do
      task = new_task(owner, ini, %{"title" => "T"})
      {:ok, comment} = Tasks.add_comment(task, owner, "original body")
      {:ok, _} = Tasks.edit_comment(comment.id, owner, "revised body")

      {:ok, view, _} = live(log_in(conn, owner), ~p"/initiatives/#{ini.id}")
      render_hook(view, "select_task", %{"id" => to_string(task.id)})

      # WL3 3.3 (§6.5): the popup is client-owned — it renders statically
      # (hidden until the open toggle flips it client-side, no round trip), so
      # the popup element and the prior text are present from first paint.
      assert has_element?(view, "#comment-versions-#{comment.id}")
      html = render(view)
      # Live body shows the revision; the history popup carries the prior text.
      assert html =~ "revised body"
      assert html =~ "original body"
    end

    test "the edit-history popup orders versions newest-first (2+ edits)", %{
      conn: conn,
      owner: owner,
      ini: ini
    } do
      task = new_task(owner, ini, %{"title" => "T"})
      {:ok, comment} = Tasks.add_comment(task, owner, "v0 original")
      # Each edit captures the prior body as a version, so after three edits the
      # version bodies are v0/v1/v2 (the live body is v3). Newest-first means the
      # most recently captured ("v2 second-edit") appears before the oldest
      # ("v0 original") in the rendered popup — this is the regression the
      # versions preload order_by guards (m02.09 WL3 3.3).
      {:ok, _} = Tasks.edit_comment(comment.id, owner, "v1 first-edit")
      {:ok, _} = Tasks.edit_comment(comment.id, owner, "v2 second-edit")
      {:ok, _} = Tasks.edit_comment(comment.id, owner, "v3 third-edit")

      {:ok, view, _} = live(log_in(conn, owner), ~p"/initiatives/#{ini.id}")
      render_hook(view, "select_task", %{"id" => to_string(task.id)})

      html = render(view)
      # All three captured versions render in the popup.
      assert html =~ "v0 original"
      assert html =~ "v1 first-edit"
      assert html =~ "v2 second-edit"

      # Newest-first ordering: the newest version body precedes the oldest in the
      # document. If the preload ever loses its order_by (the bug), these flip.
      newest_pos = pos(html, "v2 second-edit")
      oldest_pos = pos(html, "v0 original")
      assert newest_pos < oldest_pos,
             "expected versions newest-first in the popup, got oldest-first"
    end
  end

  # First byte offset of `needle` in `haystack` (for document-order assertions).
  defp pos(haystack, needle) do
    [{start, _len} | _] = :binary.matches(haystack, needle)
    start
  end
end
