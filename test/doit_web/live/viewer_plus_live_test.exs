defmodule DoItWeb.ViewerPlusLiveTest do
  @moduledoc """
  m02.05 item 12.6 — Viewer+ at the LiveView layer. A global *viewer* who is a
  task's direct assignee leads that task and its subtree: edits progress +
  comments (12.6.2), staffs descendants from the handed pool (12.6.3/12.6.4),
  and reads "viewer+" in the members panel (12.6.5). Off-setting = no grant.
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
        "name" => name,
        "password" => "password123"
      })

    u
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, user.id)
  end

  defp task(owner, init, parent, title, attrs \\ %{}) do
    parent_id = (parent && parent.id) || init.root_task_id

    {:ok, t} =
      Tasks.create_task(
        owner,
        Map.merge(%{"initiative_id" => init.id, "parent_id" => parent_id, "title" => title}, attrs)
      )

    t
  end

  # Owner + viewer B (assignee of mid-tree task `b`), a pool {x, y} on `b`, a
  # non-pool member `z`, a leaf `c` inside the led subtree, a leaf `d` outside.
  defp setup_tree(viewer_plus) do
    owner = user("Owner")
    viewer = user("Viewer")
    x = user("X")
    y = user("Y")
    z = user("Z")

    {:ok, init} =
      Initiatives.create_initiative(owner, %{"name" => "Init", "viewer_plus" => viewer_plus})

    for u <- [viewer, x, y, z], do: {:ok, _} = Initiatives.add_member(init.id, u.id, "viewer")

    a = task(owner, init, nil, "A")
    b = task(owner, init, a, "B", %{"assignee_id" => viewer.id})
    c = task(owner, init, b, "C")
    d = task(owner, init, nil, "D")

    {:ok, _} = Tasks.add_co_assignee(b, owner, x.id)
    {:ok, _} = Tasks.add_co_assignee(b, owner, y.id)

    %{owner: owner, viewer: viewer, x: x, y: y, z: z, init: init, a: a, b: b, c: c, d: d}
  end

  defp select(view, task), do: render_click(view, "select_task", %{"id" => Integer.to_string(task.id)})

  describe "viewer_plus on" do
    test "a lead edits progress + comments on the led subtree, not outside", %{conn: conn} do
      %{viewer: viewer, init: init, c: c, d: d} = setup_tree(true)
      {:ok, view, _} = live(log_in(conn, viewer), ~p"/initiatives/#{init.id}")

      # c — a leaf inside the led subtree: progress editable, comment form shown.
      select(view, c)
      refute has_element?(view, "#task-field-progress[disabled]")
      assert has_element?(view, "form[phx-submit='add_comment']")

      # d — a leaf outside the subtree: read-only.
      select(view, d)
      assert has_element?(view, "#task-field-progress[disabled]")
      refute has_element?(view, "form[phx-submit='add_comment']")
    end

    test "a lead staffs a descendant only from the handed pool", %{conn: conn} do
      %{viewer: viewer, init: init, x: x, y: y, z: z, c: c} = setup_tree(true)
      {:ok, view, _} = live(log_in(conn, viewer), ~p"/initiatives/#{init.id}")

      select(view, c)

      # The assignee select is live and lists only the pool {x, y} — never z.
      refute has_element?(view, "#task-field-assignee[disabled]")
      assert has_element?(view, "#task-field-assignee option[value='#{x.id}']")
      assert has_element?(view, "#task-field-assignee option[value='#{y.id}']")
      refute has_element?(view, "#task-field-assignee option[value='#{z.id}']")

      # The co-add dropdown is present and likewise excludes z.
      assert has_element?(view, "#add-co-assignee-form")
      assert has_element?(view, "#add-co-assignee-form option[value='#{x.id}']")
      refute has_element?(view, "#add-co-assignee-form option[value='#{z.id}']")
    end

    test "an out-of-pool co-assignee add is refused (reply ok:false)", %{conn: conn} do
      %{viewer: viewer, init: init, z: z, c: c} = setup_tree(true)
      {:ok, view, _} = live(log_in(conn, viewer), ~p"/initiatives/#{init.id}")

      select(view, c)
      render_hook(view, "add_co_assignee", %{"user_id" => Integer.to_string(z.id)})

      # Nothing landed — z is not on c's co-list.
      assert Tasks.list_co_assignees(c.id) == []
    end

    test "the led task's own co-list and title stay off-limits", %{conn: conn} do
      %{viewer: viewer, init: init, b: b} = setup_tree(true)
      {:ok, view, _} = live(log_in(conn, viewer), ~p"/initiatives/#{init.id}")

      select(view, b)
      # b is the led task: progress/comments yes, but no staffing of its own
      # co-list (owner-seeded) and the title field is read-only.
      assert has_element?(view, "#task-field-title[disabled]")
      refute has_element?(view, "#add-co-assignee-form")
    end

    test "the viewer reads \"viewer+\" in the members panel", %{conn: conn} do
      %{viewer: viewer, init: init} = setup_tree(true)
      {:ok, view, _} = live(log_in(conn, viewer), ~p"/initiatives/#{init.id}")

      assert view |> element("#members-desktop") |> render() =~ "viewer+"
    end

    test "the owner sees \"viewer+\" as the selected role option in the dropdown", %{conn: conn} do
      %{owner: owner, init: init} = setup_tree(true)
      {:ok, view, _} = live(log_in(conn, owner), ~p"/initiatives/#{init.id}")

      # The editable role select carries a selected "viewer+" option (value still
      # "viewer") rather than a separate pill.
      html = view |> element("#members-desktop") |> render()
      assert html =~ ~r/<option value="viewer" selected="">\s*viewer\+/
    end
  end

  describe "member drag → assign (item 12.8)" do
    test "an editor drop assigns primary if empty, else stacks a co", %{conn: conn} do
      %{owner: owner, x: x, y: y, init: init, d: d} = setup_tree(true)
      {:ok, view, _} = live(log_in(conn, owner), ~p"/initiatives/#{init.id}")

      drop = fn u ->
        render_hook(view, "assign_member", %{
          "user-id" => Integer.to_string(u.id),
          "task-id" => Integer.to_string(d.id)
        })
      end

      # d starts unassigned → first drop is the primary.
      drop.(x)
      assert Tasks.get_task!(d.id).assignee_id == x.id

      # Second drop stacks as a co, never clobbering the primary.
      drop.(y)
      assert Tasks.get_task!(d.id).assignee_id == x.id
      assert Tasks.list_co_assignees(d.id) |> Enum.map(& &1.user_id) == [y.id]

      # Dropping the existing primary again is a no-op (not added as a co).
      drop.(x)
      assert Tasks.get_task!(d.id).assignee_id == x.id
      assert Tasks.list_co_assignees(d.id) |> Enum.map(& &1.user_id) == [y.id]
    end

    test "a viewer+ may drop a pool member on a descendant, never an outsider", %{conn: conn} do
      %{viewer: viewer, x: x, z: z, init: init, c: c} = setup_tree(true)
      {:ok, view, _} = live(log_in(conn, viewer), ~p"/initiatives/#{init.id}")

      # c is a descendant of the led task; x is in the handed pool → assigned.
      render_hook(view, "assign_member", %{
        "user-id" => Integer.to_string(x.id),
        "task-id" => Integer.to_string(c.id)
      })

      assert Tasks.get_task!(c.id).assignee_id == x.id

      # z is outside the pool → refused, nothing changes.
      render_hook(view, "assign_member", %{
        "user-id" => Integer.to_string(z.id),
        "task-id" => Integer.to_string(c.id)
      })

      assert Tasks.get_task!(c.id).assignee_id == x.id
      assert Tasks.list_co_assignees(c.id) == []
    end

    test "a viewer+ can't assign outside their led subtree", %{conn: conn} do
      %{viewer: viewer, x: x, init: init, a: a} = setup_tree(true)
      {:ok, view, _} = live(log_in(conn, viewer), ~p"/initiatives/#{init.id}")

      # a is the ancestor of the led task — outside the grant.
      render_hook(view, "assign_member", %{
        "user-id" => Integer.to_string(x.id),
        "task-id" => Integer.to_string(a.id)
      })

      assert Tasks.get_task!(a.id).assignee_id == nil
    end
  end

  describe "viewer_plus off" do
    test "no progress grant and no viewer+ label", %{conn: conn} do
      %{viewer: viewer, init: init, c: c} = setup_tree(false)
      {:ok, view, _} = live(log_in(conn, viewer), ~p"/initiatives/#{init.id}")

      select(view, c)
      assert has_element?(view, "#task-field-progress[disabled]")
      assert has_element?(view, "#task-field-assignee[disabled]")
      refute view |> element("#members-desktop") |> render() =~ "viewer+"
    end
  end
end
