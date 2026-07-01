defmodule DoItWeb.ArchiveLiveTest do
  @moduledoc """
  m02.08 worklist 4 — per-user Archive + Hide through the UI. The index Archived
  list shows archived items by default, hides hidden items behind the
  non-persistent Show-hidden checkbox, and restores/unhides; the show page
  archives (immediately or via the 4.2 confirm) and hides.
  """
  use DoItWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

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

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, user.id)
  end

  defp new_task(actor, ini, attrs) do
    {:ok, t} =
      Tasks.create_task(
        actor,
        attrs |> Map.put("initiative_id", ini.id) |> Map.put_new("parent_id", ini.root_task_id)
      )

    t
  end

  setup %{conn: conn} do
    me = user("me")
    {:ok, archived} = Initiatives.create_initiative(me, %{"name" => "ArchivedOne"})
    {:ok, hidden} = Initiatives.create_initiative(me, %{"name" => "HiddenOne"})
    {:ok, active} = Initiatives.create_initiative(me, %{"name" => "ActiveOne"})

    %{conn: log_in(conn, me), me: me, archived: archived, hidden: hidden, active: active}
  end

  describe "index Archived list" do
    test "archived shows by default; hidden stays behind Show-hidden", ctx do
      {:ok, 1} = Initiatives.archive_initiative(ctx.me, ctx.archived)
      {:ok, 1} = Initiatives.hide_initiative(ctx.me, ctx.hidden)

      {:ok, view, _html} = live(ctx.conn, ~p"/initiatives")

      # Archived section present; archived row shown, hidden row not yet.
      assert has_element?(view, "#archived")
      assert has_element?(view, "#archived-#{ctx.archived.id}")
      refute has_element?(view, "#archived-#{ctx.hidden.id}")

      # The active one is NOT in the archived list (and IS in the main stream).
      refute has_element?(view, "#archived-#{ctx.active.id}")

      # Reveal hidden — now the hidden row appears.
      view |> element("#show-hidden") |> render_click()
      assert has_element?(view, "#archived-#{ctx.hidden.id}")
    end

    test "Show-hidden does NOT persist across visits (resets each mount)", ctx do
      {:ok, 1} = Initiatives.hide_initiative(ctx.me, ctx.hidden)

      {:ok, view, _html} = live(ctx.conn, ~p"/initiatives")
      view |> element("#show-hidden") |> render_click()
      assert has_element?(view, "#archived-#{ctx.hidden.id}")

      # Fresh mount — the checkbox state is gone; hidden is out of sight again.
      {:ok, view2, _html} = live(ctx.conn, ~p"/initiatives")
      refute has_element?(view2, "#archived-#{ctx.hidden.id}")
    end

    test "restore returns an archived Initiative to the active list", ctx do
      {:ok, 1} = Initiatives.archive_initiative(ctx.me, ctx.archived)

      {:ok, view, _html} = live(ctx.conn, ~p"/initiatives")
      view |> element("#archived-#{ctx.archived.id} button", "Restore") |> render_click()

      refute has_element?(view, "#archived-#{ctx.archived.id}")

      assert ctx.archived.id in (Initiatives.list_visible_initiatives(ctx.me)
                                 |> Enum.map(& &1.id))
    end

    test "unhide returns a hidden Initiative to the active list", ctx do
      {:ok, 1} = Initiatives.hide_initiative(ctx.me, ctx.hidden)

      {:ok, view, _html} = live(ctx.conn, ~p"/initiatives")
      view |> element("#show-hidden") |> render_click()
      view |> element("#archived-#{ctx.hidden.id} button", "Unhide") |> render_click()

      assert ctx.hidden.id in (Initiatives.list_visible_initiatives(ctx.me) |> Enum.map(& &1.id))
    end
  end

  describe "index Trash (merged into the Archive drawer, m03.01 item 5.3)" do
    test "drawer title omits \"Trash\" with nothing trashed; includes it with a count once trashed",
         ctx do
      {:ok, 1} = Initiatives.archive_initiative(ctx.me, ctx.archived)

      {:ok, view, _html} = live(ctx.conn, ~p"/initiatives")
      refute view |> element("#archived summary") |> render() =~ "Trash"

      {:ok, _} = Initiatives.trash_initiative(ctx.active)

      {:ok, view2, _html} = live(ctx.conn, ~p"/initiatives")
      assert view2 |> element("#archived summary") |> render() =~ "Trash (1)"
    end

    test "a trashed Initiative's row stays hidden until Show-trash is checked", ctx do
      {:ok, _} = Initiatives.trash_initiative(ctx.active)

      {:ok, view, _html} = live(ctx.conn, ~p"/initiatives")
      refute has_element?(view, "#trashed-#{ctx.active.id}")

      view |> element("#show-trash") |> render_click()
      assert has_element?(view, "#trashed-#{ctx.active.id}")
    end

    test "Show-trash does NOT persist across visits (resets each mount)", ctx do
      {:ok, _} = Initiatives.trash_initiative(ctx.active)

      {:ok, view, _html} = live(ctx.conn, ~p"/initiatives")
      view |> element("#show-trash") |> render_click()
      assert has_element?(view, "#trashed-#{ctx.active.id}")

      # Fresh mount — the checkbox state is gone; trash is out of sight again.
      {:ok, view2, _html} = live(ctx.conn, ~p"/initiatives")
      refute has_element?(view2, "#trashed-#{ctx.active.id}")
    end

    test "restore from the drawer returns a trashed Initiative to the active list", ctx do
      {:ok, _} = Initiatives.trash_initiative(ctx.active)

      {:ok, view, _html} = live(ctx.conn, ~p"/initiatives")
      view |> element("#show-trash") |> render_click()
      view |> element("#trashed-#{ctx.active.id} button", "Restore") |> render_click()

      refute has_element?(view, "#trashed-#{ctx.active.id}")

      assert ctx.active.id in (Initiatives.list_visible_initiatives(ctx.me) |> Enum.map(& &1.id))
    end
  end

  describe "show page archive + hide" do
    # The archive confirm opens CLIENT-SIDE now (no round trip, UX_GUARDRAILS
    # 6.5) — the owner case predicts from the DOM, the member case via the
    # server backstop here. So these exercise the server contract; the modal
    # itself is [Human]/JS-verified (no e2e rig).
    test "archive with no unfinished work commits immediately", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/initiatives/#{ctx.active.id}")

      # Clean tree → the client pushes archive_initiative; the server commits
      # and navigates to the index.
      render_hook(view, "archive_initiative", %{})
      assert_redirect(view, ~p"/initiatives")

      assert ctx.active.id in (Initiatives.list_archived_initiatives(ctx.me) |> Enum.map(& &1.id))
    end

    test "archive with unfinished work needs a confirm; confirmed commits", ctx do
      _open = new_task(ctx.me, ctx.active, %{"title" => "Unfinished"})

      {:ok, view, _html} = live(ctx.conn, ~p"/initiatives/#{ctx.active.id}")

      # Without `confirmed`, the server backstop refuses to commit (it replies
      # needs_confirm so the client opens the modal) — nothing is archived.
      render_hook(view, "archive_initiative", %{})
      refute ctx.active.id in (Initiatives.list_archived_initiatives(ctx.me) |> Enum.map(& &1.id))

      # Proceed → confirmed: true commits + navigates.
      render_hook(view, "archive_initiative", %{"confirmed" => true})
      assert_redirect(view, ~p"/initiatives")
      assert ctx.active.id in (Initiatives.list_archived_initiatives(ctx.me) |> Enum.map(& &1.id))
    end

    test "hide drops it from the active list immediately", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/initiatives/#{ctx.active.id}")

      view |> element("#hide-initiative-btn") |> render_click()
      assert_redirect(view, ~p"/initiatives")

      refute ctx.active.id in (Initiatives.list_visible_initiatives(ctx.me) |> Enum.map(& &1.id))
    end
  end

  describe "archive-on-completion prompt (item 4.1)" do
    test "completing the last task raises the prompt; it never auto-archives", ctx do
      task = new_task(ctx.me, ctx.active, %{"title" => "Last one"})

      {:ok, view, _html} = live(ctx.conn, ~p"/initiatives/#{ctx.active.id}")

      # Not shown while work remains.
      refute has_element?(view, "#archive-prompt")

      # Crossing to 100% raises the dismissible prompt (no auto-archive).
      view |> render_hook("toggle_complete", %{"id" => to_string(task.id)})
      assert has_element?(view, "#archive-prompt")
      assert ctx.active.id in (Initiatives.list_visible_initiatives(ctx.me) |> Enum.map(& &1.id))

      # Dismiss closes it without archiving.
      view
      |> element("#archive-prompt button[phx-click='dismiss_archive_prompt']")
      |> render_click()

      refute has_element?(view, "#archive-prompt")
      assert ctx.active.id in (Initiatives.list_visible_initiatives(ctx.me) |> Enum.map(& &1.id))
    end

    test "an Initiative already complete on entry does NOT nag", ctx do
      task = new_task(ctx.me, ctx.active, %{"title" => "Already"})
      {:ok, _} = Tasks.toggle_complete(task, ctx.me)

      {:ok, view, _html} = live(ctx.conn, ~p"/initiatives/#{ctx.active.id}")
      refute has_element?(view, "#archive-prompt")
    end
  end
end
