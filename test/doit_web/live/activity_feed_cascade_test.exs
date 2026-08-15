defmodule DoItWeb.ActivityFeedCascadeTest do
  @moduledoc """
  The task pane's activity feed shows completion events with their cascade
  (m03.04 2.36): a status_changed line renders (the m02-era hide is gone
  now that flips are one atomic event and no-ops don't record), and a flip
  that carried other tasks along wears a compact "+N cascaded" marker — a
  count, never ids. A single-task flip stays marker-free.
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

  defp create_task!(owner, ini, parent_id, title) do
    {:ok, task} =
      Tasks.create_task(owner, %{
        "initiative_id" => ini.id,
        "parent_id" => parent_id,
        "title" => title
      })

    task
  end

  test "a cascading completion wears the marker; a single-task flip does not", %{conn: conn} do
    owner = user("owner")
    {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Feed"})

    branch = create_task!(owner, ini, ini.root_task_id, "Branch")
    leaf_a = create_task!(owner, ini, branch.id, "Leaf A")
    leaf_b = create_task!(owner, ini, branch.id, "Leaf B")

    # Leaf A alone cascades nothing; Leaf B completes the branch and the root.
    {:ok, _} = Tasks.toggle_complete(leaf_a, owner)
    {:ok, _} = Tasks.toggle_complete(Tasks.get_task(leaf_b.id), owner)

    {:ok, view, _html} = live(log_in(conn, owner), ~p"/initiatives/#{ini.id}")

    render_hook(view, "select_task", %{"id" => to_string(leaf_b.id)})
    assert has_element?(view, "#task-activity li", "completed")
    assert has_element?(view, "#task-activity [data-cascade]", "+2 cascaded")

    render_hook(view, "select_task", %{"id" => to_string(leaf_a.id)})
    assert has_element?(view, "#task-activity li", "completed")
    refute has_element?(view, "#task-activity [data-cascade]")
  end
end
