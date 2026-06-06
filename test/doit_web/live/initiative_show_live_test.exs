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

    test "selecting a leaf shows the editable slider, no branch hint", %{
      conn: conn,
      initiative: initiative,
      child: child
    } do
      {:ok, view, _html} = live(conn, open_path(initiative))

      select_task(view, child.id)

      refute render(view) =~ "Ignored — this task has subtasks."
      refute has_element?(view, "#mp-hint-#{child.id}-pop")
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
      {:ok, view, _html} = live(conn, open_path(initiative))
      render_click(view, "edit_initiative", %{})

      assert has_element?(view, "button[phx-click=delete_initiative]")

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> element("button[phx-click=delete_initiative]") |> render_click()

      assert to == ~p"/initiatives"
      refute Initiatives.get_initiative(initiative.id)
    end
  end
end
