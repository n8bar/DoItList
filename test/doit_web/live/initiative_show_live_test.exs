defmodule DoItWeb.InitiativeShowLiveTest do
  @moduledoc """
  LiveView tests for the keyboard alternative to drag-and-drop reorganization
  (M02 Arc 3 item 6). When a task is selected (Details panel open), Alt+arrow
  keys reorder/reparent the selected task.
  """
  use DoItWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DoIt.{Accounts, Initiatives, Tasks}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp register_and_log_in(conn) do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "kbd-#{System.unique_integer([:positive])}@example.com",
        "username" => "kbd-#{System.unique_integer([:positive])}",
        "name" => "Kbd User",
        "password" => "password123"
      })

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    {conn, user}
  end

  defp create_initiative(user) do
    {:ok, initiative} = Initiatives.create_initiative(user, %{"name" => "Kbd Initiative"})
    initiative
  end

  # Single-root model: no explicit parent means "top level" = a child of the
  # Initiative's system root task.
  defp create_task(user, initiative, parent, title) do
    parent_id = (parent && parent.id) || initiative.root_task_id

    {:ok, task} =
      Tasks.create_task(user, %{
        "initiative_id" => initiative.id,
        "parent_id" => parent_id,
        "title" => title
      })

    task
  end

  # Order siblings of `parent_id` (or the root task's children when nil) by sort_order.
  defp sibling_order(initiative_id, nil) do
    import Ecto.Query

    root_id =
      DoIt.Repo.one(
        from i in DoIt.Initiatives.Initiative,
          where: i.id == ^initiative_id,
          select: i.root_task_id
      )

    sibling_order(initiative_id, root_id)
  end

  defp sibling_order(initiative_id, parent_id) do
    import Ecto.Query

    DoIt.Repo.all(
      from t in DoIt.Tasks.Task,
        where: t.initiative_id == ^initiative_id and t.parent_id == ^parent_id,
        order_by: [asc: t.sort_order, asc: t.inserted_at],
        select: t.id
    )
  end

  defp open_path(initiative), do: ~p"/initiatives/#{initiative.id}"

  defp select_task(view, task_id) do
    render_click(view, "select_task", %{"id" => Integer.to_string(task_id)})
  end

  defp send_kbd(view, key, opts \\ []) do
    payload = %{
      "key" => key,
      "altKey" => Keyword.get(opts, :alt, true),
      "ctrlKey" => Keyword.get(opts, :ctrl, false),
      "metaKey" => Keyword.get(opts, :meta, false),
      "shiftKey" => Keyword.get(opts, :shift, false)
    }

    render_keydown(view, "kbd_move", payload)
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "Alt+ArrowUp / ArrowDown reorder among siblings" do
    setup %{conn: conn} do
      {conn, user} = register_and_log_in(conn)
      initiative = create_initiative(user)
      a = create_task(user, initiative, nil, "A")
      b = create_task(user, initiative, nil, "B")
      c = create_task(user, initiative, nil, "C")

      %{conn: conn, user: user, initiative: initiative, a: a, b: b, c: c}
    end

    test "Alt+ArrowUp moves the selected task up among siblings", %{
      conn: conn,
      initiative: initiative,
      b: b,
      a: a,
      c: c
    } do
      {:ok, view, _html} = live(conn, open_path(initiative))

      assert sibling_order(initiative.id, nil) == [a.id, b.id, c.id]

      select_task(view, b.id)
      send_kbd(view, "ArrowUp")

      assert sibling_order(initiative.id, nil) == [b.id, a.id, c.id]
    end

    test "Alt+ArrowDown moves the selected task down among siblings", %{
      conn: conn,
      initiative: initiative,
      b: b,
      a: a,
      c: c
    } do
      {:ok, view, _html} = live(conn, open_path(initiative))

      select_task(view, b.id)
      send_kbd(view, "ArrowDown")

      assert sibling_order(initiative.id, nil) == [a.id, c.id, b.id]
    end

    test "Alt+ArrowUp on the first sibling is a no-op", %{
      conn: conn,
      initiative: initiative,
      a: a,
      b: b,
      c: c
    } do
      {:ok, view, _html} = live(conn, open_path(initiative))

      select_task(view, a.id)
      send_kbd(view, "ArrowUp")

      assert sibling_order(initiative.id, nil) == [a.id, b.id, c.id]
    end

    test "Alt+ArrowDown on the last sibling is a no-op", %{
      conn: conn,
      initiative: initiative,
      a: a,
      b: b,
      c: c
    } do
      {:ok, view, _html} = live(conn, open_path(initiative))

      select_task(view, c.id)
      send_kbd(view, "ArrowDown")

      assert sibling_order(initiative.id, nil) == [a.id, b.id, c.id]
    end
  end

  describe "Alt+ArrowRight indents under the previous sibling" do
    setup %{conn: conn} do
      {conn, user} = register_and_log_in(conn)
      initiative = create_initiative(user)
      a = create_task(user, initiative, nil, "A")
      b = create_task(user, initiative, nil, "B")

      %{conn: conn, user: user, initiative: initiative, a: a, b: b}
    end

    test "Alt+ArrowRight makes the selected task a child of its previous sibling", %{
      conn: conn,
      initiative: initiative,
      a: a,
      b: b
    } do
      {:ok, view, _html} = live(conn, open_path(initiative))

      assert sibling_order(initiative.id, nil) == [a.id, b.id]

      select_task(view, b.id)
      send_kbd(view, "ArrowRight")

      assert sibling_order(initiative.id, nil) == [a.id]
      assert sibling_order(initiative.id, a.id) == [b.id]

      moved = Tasks.get_task!(b.id)
      assert moved.parent_id == a.id
    end

    test "Alt+ArrowRight on the first sibling is a no-op", %{
      conn: conn,
      initiative: initiative,
      a: a,
      b: b
    } do
      {:ok, view, _html} = live(conn, open_path(initiative))

      select_task(view, a.id)
      send_kbd(view, "ArrowRight")

      assert sibling_order(initiative.id, nil) == [a.id, b.id]
      assert Tasks.get_task!(a.id).parent_id == initiative.root_task_id
    end
  end

  describe "keyboard move honors the completion-flip confirm" do
    setup %{conn: conn} do
      {conn, user} = register_and_log_in(conn)
      initiative = create_initiative(user)
      # P is a done branch (its only child is done); L is an incomplete leaf
      # right after it. Indenting L under P would uncomplete P — scenario 1.
      p = create_task(user, initiative, nil, "P")
      d = create_task(user, initiative, p, "D")
      {:ok, _} = Tasks.toggle_complete(d, user)
      l = create_task(user, initiative, nil, "L")

      %{conn: conn, user: user, initiative: initiative, p: p, l: l}
    end

    test "indent into a done branch raises the modal; Proceed commits move + flip", %{
      conn: conn,
      initiative: initiative,
      p: p,
      l: l
    } do
      assert Tasks.get_task!(p.id).status == "done"

      {:ok, view, _html} = live(conn, open_path(initiative))

      select_task(view, l.id)
      send_kbd(view, "ArrowRight")

      # Not moved yet — the styled confirm gates it, same as a drag.
      assert has_element?(view, "#confirm-form")
      assert Tasks.get_task!(l.id).parent_id == initiative.root_task_id

      render_click(view, "confirm_pending", %{})

      assert Tasks.get_task!(l.id).parent_id == p.id
      assert Tasks.get_task!(p.id).status == "open"
    end

    test "Cancel leaves the tree untouched", %{
      conn: conn,
      initiative: initiative,
      p: p,
      l: l
    } do
      {:ok, view, _html} = live(conn, open_path(initiative))

      select_task(view, l.id)
      send_kbd(view, "ArrowRight")
      render_click(view, "cancel_pending", %{})

      refute has_element?(view, "#confirm-form")
      assert Tasks.get_task!(l.id).parent_id == initiative.root_task_id
      assert Tasks.get_task!(p.id).status == "done"
    end
  end

  describe "Alt+ArrowLeft dedents to the grandparent" do
    setup %{conn: conn} do
      {conn, user} = register_and_log_in(conn)
      initiative = create_initiative(user)

      # Tree:
      #   parent (root)
      #     child  <- selected, will dedent
      #   sibling_root
      parent = create_task(user, initiative, nil, "Parent")
      child = create_task(user, initiative, parent, "Child")
      sibling_root = create_task(user, initiative, nil, "SiblingRoot")

      %{
        conn: conn,
        user: user,
        initiative: initiative,
        parent: parent,
        child: child,
        sibling_root: sibling_root
      }
    end

    test "Alt+ArrowLeft moves child to grandparent's children, right after parent", %{
      conn: conn,
      initiative: initiative,
      parent: parent,
      child: child,
      sibling_root: sibling_root
    } do
      {:ok, view, _html} = live(conn, open_path(initiative))

      assert sibling_order(initiative.id, nil) == [parent.id, sibling_root.id]
      assert sibling_order(initiative.id, parent.id) == [child.id]

      select_task(view, child.id)
      send_kbd(view, "ArrowLeft")

      # `child` should now sit between parent and sibling_root at root level.
      assert sibling_order(initiative.id, nil) == [parent.id, child.id, sibling_root.id]
      assert sibling_order(initiative.id, parent.id) == []

      moved = Tasks.get_task!(child.id)
      assert moved.parent_id == initiative.root_task_id
    end

    test "Alt+ArrowLeft on a root task is a no-op", %{
      conn: conn,
      initiative: initiative,
      parent: parent,
      sibling_root: sibling_root
    } do
      {:ok, view, _html} = live(conn, open_path(initiative))

      select_task(view, parent.id)
      send_kbd(view, "ArrowLeft")

      assert sibling_order(initiative.id, nil) == [parent.id, sibling_root.id]
      assert Tasks.get_task!(parent.id).parent_id == initiative.root_task_id
    end
  end

  describe "permissive fallthrough" do
    setup %{conn: conn} do
      {conn, user} = register_and_log_in(conn)
      initiative = create_initiative(user)
      a = create_task(user, initiative, nil, "A")
      b = create_task(user, initiative, nil, "B")

      %{conn: conn, user: user, initiative: initiative, a: a, b: b}
    end

    test "keypress without Alt is ignored", %{conn: conn, initiative: initiative, a: a, b: b} do
      {:ok, view, _html} = live(conn, open_path(initiative))

      select_task(view, b.id)

      # No alt modifier — should be a no-op.
      send_kbd(view, "ArrowUp", alt: false)
      assert sibling_order(initiative.id, nil) == [a.id, b.id]

      # Shift+ArrowUp — alt is false, should also be ignored.
      send_kbd(view, "ArrowUp", alt: false, shift: true)
      assert sibling_order(initiative.id, nil) == [a.id, b.id]

      # Ctrl+ArrowUp — alt is false, should also be ignored.
      send_kbd(view, "ArrowUp", alt: false, ctrl: true)
      assert sibling_order(initiative.id, nil) == [a.id, b.id]
    end

    test "non-arrow keys are ignored", %{conn: conn, initiative: initiative, a: a, b: b} do
      {:ok, view, _html} = live(conn, open_path(initiative))

      select_task(view, b.id)
      send_kbd(view, "k")

      assert sibling_order(initiative.id, nil) == [a.id, b.id]
    end

    test "keypress with no task selected is a no-op", %{
      conn: conn,
      initiative: initiative,
      a: a,
      b: b
    } do
      {:ok, view, _html} = live(conn, open_path(initiative))

      # No selection. Alt+ArrowUp must not crash and must not reorder.
      send_kbd(view, "ArrowUp")

      assert sibling_order(initiative.id, nil) == [a.id, b.id]
    end
  end

  describe "manual-progress on branches (item 19)" do
    setup %{conn: conn} do
      {conn, user} = register_and_log_in(conn)
      initiative = create_initiative(user)
      branch = create_task(user, initiative, nil, "Branch")
      child = create_task(user, initiative, branch, "Child")

      %{conn: conn, initiative: initiative, branch: branch, child: child}
    end

    test "selecting a branch shows a disabled slider, hint, and info popover", %{
      conn: conn,
      initiative: initiative,
      branch: branch
    } do
      {:ok, view, _html} = live(conn, open_path(initiative))

      select_task(view, branch.id)

      assert has_element?(view, "input[type=range][disabled]")
      assert has_element?(view, "#mp-hint-#{branch.id}-pop")
      assert render(view) =~ "Ignored — this task has subtasks."
      assert render(view) =~ "Computed from children:"
    end

    test "selecting a leaf enables the slider; branch copy keeps its space, invisible", %{
      conn: conn,
      initiative: initiative,
      child: child
    } do
      {:ok, view, _html} = live(conn, open_path(initiative))

      select_task(view, child.id)

      assert has_element?(view, "#task-editor-pane input[type=range]:not([disabled])")
      # Reserved space (UX_GUARDRAILS 1.1): the branch-only copy stays in the
      # DOM, invisible, so leaf↔branch switches don't shift the layout.
      assert has_element?(view, "#task-editor-pane p.invisible")
      refute has_element?(view, "#mp-hint-#{child.id}-pop")
    end
  end

  describe "incremental tree patch (.03.04.03)" do
    setup %{conn: conn} do
      {conn, user} = register_and_log_in(conn)
      initiative = create_initiative(user)
      parent = create_task(user, initiative, nil, "Patch parent")
      leaf = create_task(user, initiative, parent, "Patch leaf")

      %{conn: conn, user: user, initiative: initiative, parent: parent, leaf: leaf}
    end

    test "a collaborator's update broadcast patches the rendered tree", %{
      conn: conn,
      user: user,
      initiative: initiative,
      leaf: leaf
    } do
      {:ok, view, _html} = live(conn, open_path(initiative))

      {:ok, _} = Tasks.update_task(Tasks.get_task!(leaf.id), user, %{"title" => "Renamed live"})

      assert render(view) =~ "Renamed live"
    end

    test "a leaf completion patches ancestor roll-up in the rendered tree", %{
      conn: conn,
      initiative: initiative,
      parent: parent,
      leaf: leaf
    } do
      {:ok, view, _html} = live(conn, open_path(initiative))

      render_click(view, "toggle_complete", %{"id" => Integer.to_string(leaf.id)})

      assert Tasks.get_task!(parent.id).status == "done"
      assert has_element?(view, "#task-#{parent.id} [data-complete-toggle][aria-pressed='true']")
    end

    test "a deep change re-sorting a progress-keyed ancestor level reaches the view", %{
      conn: conn,
      user: user,
      initiative: initiative
    } do
      # G sorts its children by completion %; X (branch with one leaf) and Y
      # (open leaf) start at 0%. Completing X's leaf raises X to 100%, which
      # must re-sort G's level — two levels above the written task.
      g = create_task(user, initiative, nil, "G")
      x = create_task(user, initiative, g, "X branch")
      deep = create_task(user, initiative, x, "deep leaf")
      y = create_task(user, initiative, g, "Y leaf")
      {:ok, _} = Tasks.set_sort(Tasks.get_task!(g.id), user, "completion", false)

      {:ok, view, _html} = live(conn, open_path(initiative))
      assert sibling_order(initiative.id, g.id) == [x.id, y.id]

      # A collaborator (direct context call → broadcast) completes the deep leaf.
      {:ok, _} = Tasks.toggle_complete(Tasks.get_task!(deep.id), user)

      assert sibling_order(initiative.id, g.id) == [y.id, x.id]

      html = render(view)
      {y_pos, _} = :binary.match(html, "Y leaf")
      {x_pos, _} = :binary.match(html, "X branch")
      assert y_pos < x_pos
    end

    test "a collaborator's set_sort resort reaches the rendered tree", %{
      conn: conn,
      user: user,
      initiative: initiative,
      parent: parent
    } do
      create_task(user, initiative, parent, "alpha")
      # setup's "Patch leaf" sorts after "alpha" alphabetically.

      {:ok, view, _html} = live(conn, open_path(initiative))

      {:ok, _} = Tasks.set_sort(Tasks.get_task!(parent.id), user, "alphabetical", false)

      html = render(view)
      {a_pos, _} = :binary.match(html, "alpha")
      {p_pos, _} = :binary.match(html, "Patch leaf")
      assert a_pos < p_pos
    end

    test "an attribute change under an auto-sorted parent re-keys sibling order", %{
      conn: conn,
      user: user,
      initiative: initiative,
      parent: parent,
      leaf: leaf
    } do
      bravo = create_task(user, initiative, parent, "bravo")
      {:ok, _} = Tasks.set_sort(Tasks.get_task!(parent.id), user, "alphabetical", false)

      {:ok, view, _html} = live(conn, open_path(initiative))

      # Rename the first leaf so it sorts after "bravo".
      select_task(view, leaf.id)
      render_submit(view, "update_task", %{"task" => %{"title" => "zulu"}})

      html = render(view)
      {z_pos, _} = :binary.match(html, "zulu")
      {b_pos, _} = :binary.match(html, "bravo")
      assert b_pos < z_pos
      assert hd(sibling_order(initiative.id, parent.id)) == bravo.id
    end
  end

  describe "move_task persistence (drag parity)" do
    setup %{conn: conn} do
      {conn, user} = register_and_log_in(conn)
      initiative = create_initiative(user)
      %{conn: conn, user: user, initiative: initiative}
    end

    test "a plain cross-parent move persists to the DB", %{
      conn: conn,
      user: user,
      initiative: initiative
    } do
      p1 = create_task(user, initiative, nil, "P1")
      p2 = create_task(user, initiative, nil, "P2")
      x = create_task(user, initiative, p1, "X")

      {:ok, view, _html} = live(conn, open_path(initiative))

      render_hook(view, "move_task", %{
        "task_id" => x.id,
        "parent_id" => p2.id,
        "position" => nil,
        "reorder" => false
      })

      assert Tasks.get_task!(x.id).parent_id == p2.id
    end

    test "a completion-flipping move waits for confirm, then persists", %{
      conn: conn,
      user: user,
      initiative: initiative
    } do
      p = create_task(user, initiative, nil, "P")
      c1 = create_task(user, initiative, p, "C1")
      c2 = create_task(user, initiative, p, "C2")

      # One child done, one open → P sits at 50%/open. Moving the open child
      # out leaves only the done child → P would cross to complete (scenario 2),
      # which requires confirmation before it commits.
      {:ok, _} = Tasks.toggle_complete(c1, user)

      {:ok, view, _html} = live(conn, open_path(initiative))

      render_hook(view, "move_task", %{
        "task_id" => c2.id,
        "parent_id" => initiative.root_task_id,
        "position" => 0,
        "reorder" => false
      })

      # Not yet committed: still under P, confirm modal showing.
      assert Tasks.get_task!(c2.id).parent_id == p.id
      assert has_element?(view, "#confirm-form")

      render_click(view, "confirm_pending", %{})

      # Proceed actually moves it to the root task, and releases the client's
      # held optimistic placement (§8.20 — the commit's render owns it now).
      assert Tasks.get_task!(c2.id).parent_id == initiative.root_task_id
      assert_push_event(view, "confirm-resolved", %{})
    end

    test "cancelling a flip-confirmed move announces the revert (§8.20)", %{
      conn: conn,
      user: user,
      initiative: initiative
    } do
      p = create_task(user, initiative, nil, "P")
      c1 = create_task(user, initiative, p, "C1")
      c2 = create_task(user, initiative, p, "C2")
      {:ok, _} = Tasks.toggle_complete(c1, user)

      {:ok, view, _html} = live(conn, open_path(initiative))

      render_hook(view, "move_task", %{
        "task_id" => c2.id,
        "parent_id" => initiative.root_task_id,
        "position" => 0,
        "reorder" => false
      })

      assert has_element?(view, "#confirm-form")
      render_click(view, "cancel_pending", %{})

      # The client holds the dragged row in its dropped spot while the modal
      # decides; "confirm-cancelled" is what sends it home.
      assert_push_event(view, "confirm-cancelled", %{})
      refute has_element?(view, "#confirm-form")
      assert Tasks.get_task!(c2.id).parent_id == p.id
    end

    test "the full §8.20 cycle: cancel, redo the same move, proceed", %{
      conn: conn,
      user: user,
      initiative: initiative
    } do
      # A: every child done except one. P: fully done.
      a = create_task(user, initiative, nil, "A")
      ad = create_task(user, initiative, a, "A done")
      {:ok, _} = Tasks.toggle_complete(ad, user)
      l = create_task(user, initiative, a, "Mover")
      p = create_task(user, initiative, nil, "P")
      pd = create_task(user, initiative, p, "P done")
      {:ok, _} = Tasks.toggle_complete(pd, user)

      {:ok, view, _html} = live(conn, open_path(initiative))

      move = %{"task_id" => l.id, "parent_id" => p.id, "position" => 0, "reorder" => false}

      # Both flips listed: A would complete, P would reopen.
      render_hook(view, "move_task", move)
      assert has_element?(view, "#confirm-form")
      assert render(view) =~ "A"
      assert render(view) =~ "P"

      # While the modal decides, the flip rows hold the maybe-write hue AND
      # the indeterminate bar (.03.07.23) — but never the moved row itself.
      assert has_element?(view, "#task-#{a.id} > [data-task-row].is-recomputing")
      assert has_element?(view, "#task-#{p.id} > [data-task-row].is-recomputing")
      refute has_element?(view, "#task-#{l.id} > [data-task-row].is-recomputing")

      render_click(view, "cancel_pending", %{})
      assert Tasks.get_task!(l.id).parent_id == a.id
      assert Tasks.get_task!(a.id).status == "open"
      assert Tasks.get_task!(p.id).status == "done"

      # Redo the identical move; this time proceed.
      render_hook(view, "move_task", move)
      assert has_element?(view, "#confirm-form")
      render_click(view, "confirm_pending", %{})

      assert Tasks.get_task!(l.id).parent_id == p.id
      assert Tasks.get_task!(a.id).status == "done"
      assert Tasks.get_task!(p.id).status == "open"
    end
  end

  describe "keyboard attribute adjusters (P / W / A)" do
    setup %{conn: conn} do
      {conn, user} = register_and_log_in(conn)
      initiative = create_initiative(user)
      t = create_task(user, initiative, nil, "T")
      %{conn: conn, user: user, initiative: initiative, t: t}
    end

    defp adjust(view, field, dir) do
      render_hook(view, "kbd_adjust", %{"field" => field, "dir" => dir})
    end

    test "P steps priority up toward high and clamps", %{conn: conn, initiative: initiative, t: t} do
      {:ok, view, _html} = live(conn, open_path(initiative))
      select_task(view, t.id)

      assert Tasks.get_task!(t.id).priority == "normal"
      adjust(view, "priority", "up")
      assert Tasks.get_task!(t.id).priority == "high"
      adjust(view, "priority", "up")
      assert Tasks.get_task!(t.id).priority == "high"
    end

    test "Shift+P steps priority down and clamps at low", %{
      conn: conn,
      initiative: initiative,
      t: t
    } do
      {:ok, view, _html} = live(conn, open_path(initiative))
      select_task(view, t.id)

      adjust(view, "priority", "down")
      assert Tasks.get_task!(t.id).priority == "low"
      adjust(view, "priority", "down")
      assert Tasks.get_task!(t.id).priority == "low"
    end

    test "A cycles assignee through Unassigned and members with wrap", %{
      conn: conn,
      user: user,
      initiative: initiative,
      t: t
    } do
      {:ok, view, _html} = live(conn, open_path(initiative))
      select_task(view, t.id)

      assert Tasks.get_task!(t.id).assignee_id == nil
      adjust(view, "assignee", "up")
      assert Tasks.get_task!(t.id).assignee_id == user.id
      # only [Unassigned, owner] → wraps back to Unassigned
      adjust(view, "assignee", "up")
      assert Tasks.get_task!(t.id).assignee_id == nil
    end

    test "create_task places by its own params: sibling after, subtask, top-level", %{
      conn: conn,
      user: user,
      initiative: initiative,
      t: t
    } do
      # Form opening is client-only now (UX_GUARDRAILS 6.5; e2e covers the
      # keystrokes) — the submit carries parent_id/after_id itself.
      child = create_task(user, initiative, t, "child")

      {:ok, view, _html} = live(conn, open_path(initiative))

      render_hook(view, "create_task", %{
        "title" => "sib",
        "parent_id" => Integer.to_string(t.id),
        "after_id" => Integer.to_string(child.id)
      })

      assert [_, _] = sibling_order(initiative.id, t.id)
      assert hd(sibling_order(initiative.id, t.id)) == child.id

      render_hook(view, "create_task", %{
        "title" => "kid",
        "parent_id" => Integer.to_string(child.id),
        "after_id" => ""
      })

      assert length(sibling_order(initiative.id, child.id)) == 1

      render_hook(view, "create_task", %{"title" => "top", "parent_id" => "", "after_id" => ""})

      top = sibling_order(initiative.id, nil)
      assert length(top) == 2
      assert hd(top) != t.id
    end
  end

  describe "delete task (client-confirmed, .03.07.15)" do
    setup %{conn: conn} do
      {conn, user} = register_and_log_in(conn)
      initiative = create_initiative(user)
      t = create_task(user, initiative, nil, "Doomed")
      %{conn: conn, user: user, initiative: initiative, t: t}
    end

    test "delete_task removes the task; the confirm dialog never hits the server", %{
      conn: conn,
      initiative: initiative,
      t: t
    } do
      {:ok, view, html} = live(conn, open_path(initiative))

      # The dialog ships in the initial render (hidden, phx-update="ignore");
      # opening it is pure client work.
      assert html =~ "delete-confirm"

      render_hook(view, "delete_task", %{"id" => Integer.to_string(t.id)})

      assert Tasks.get_task(t.id) == nil
      refute has_element?(view, "#task-#{t.id}")
    end
  end

  describe "delete initiative" do
    setup %{conn: conn} do
      {conn, user} = register_and_log_in(conn)
      initiative = create_initiative(user)
      create_task(user, initiative, nil, "A list")
      %{conn: conn, initiative: initiative}
    end

    test "owner deletes from the details pane and is redirected", %{
      conn: conn,
      initiative: initiative
    } do
      {:ok, view, html} = live(conn, open_path(initiative))

      # The confirm dialog is client-rendered (.03.07.18) and ships in the
      # initial render; delete_initiative arrives only after the user confirms.
      assert html =~ "delete-initiative-confirm"
      assert has_element?(view, "#delete-initiative-btn")

      assert {:error, {:live_redirect, %{to: to}}} =
               render_click(view, "delete_initiative", %{})

      assert to == ~p"/initiatives"
      refute Initiatives.get_initiative(initiative.id)
    end
  end

  describe "show-task-activity preference (m02.04 §2.4)" do
    test "pane hides the Activity section when the pref is off", %{conn: conn} do
      {conn, user} = register_and_log_in(conn)
      initiative = create_initiative(user)
      task = create_task(user, initiative, nil, "Watched")

      {:ok, view, _} = live(conn, ~p"/initiatives/#{initiative.id}")
      render_click(view, "select_task", %{"id" => to_string(task.id)})
      assert render(view) =~ ">Activity<"

      {:ok, _} = Accounts.update_preferences(user, %{"show_task_activity" => "false"})

      {:ok, view, _} = live(conn, ~p"/initiatives/#{initiative.id}")
      render_click(view, "select_task", %{"id" => to_string(task.id)})
      refute render(view) =~ ">Activity<"
    end
  end

  describe "selection presence (m02.04 §1.12)" do
    setup %{conn: conn} do
      {conn_a, user_a} = register_and_log_in(conn)
      {conn_b, user_b} = register_and_log_in(conn)
      initiative = create_initiative(user_a)
      {:ok, _} = Initiatives.add_member(initiative.id, user_b.id, "editor")
      task = create_task(user_a, initiative, nil, "Watched task")

      %{conn_a: conn_a, conn_b: conn_b, user_b: user_b, initiative: initiative, task: task}
    end

    # A presence diff can arrive in several pushes (joins first, then the
    # selection); walk them until one carries what we're waiting for.
    defp await_selection_push(view, fun, attempts \\ 10)
    defp await_selection_push(_view, _fun, 0), do: flunk("no presence push matched")

    defp await_selection_push(view, fun, attempts) do
      assert_push_event(view, "presence-selections", %{selections: selections}, 1000)
      if fun.(selections), do: selections, else: await_selection_push(view, fun, attempts - 1)
    end

    test "another member's select/deselect reaches this client; own selection is excluded",
         %{conn_a: conn_a, conn_b: conn_b, user_b: user_b, initiative: initiative, task: task} do
      {:ok, view_a, _} = live(conn_a, ~p"/initiatives/#{initiative.id}")
      {:ok, view_b, _} = live(conn_b, ~p"/initiatives/#{initiative.id}")

      render_click(view_b, "select_task", %{"id" => to_string(task.id)})

      selections =
        await_selection_push(view_a, fn sels ->
          Enum.any?(sels, &(&1.user_id == user_b.id and &1.task_id == task.id))
        end)

      badge = Enum.find(selections, &(&1.user_id == user_b.id))
      assert badge.initials != ""
      assert String.starts_with?(badge.bg, "linear-gradient(")
      assert String.starts_with?(badge.fg, "#")

      # B's own client never gets B's selection back.
      assert_push_event(view_b, "presence-selections", %{selections: own})
      refute Enum.any?(own, &(&1.user_id == user_b.id))

      render_click(view_b, "close_task", %{})

      await_selection_push(view_a, fn sels ->
        not Enum.any?(sels, &(&1.user_id == user_b.id))
      end)
    end
  end
end
