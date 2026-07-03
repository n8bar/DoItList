defmodule DoItWeb.InitiativeWorkspaceRollupBroadcastTest do
  @moduledoc """
  m03.02 item 2: a `{:task_updated, id}` broadcast for a leaf edit or a
  completion-cascade flip patches the RECEIVING LiveView's ancestor chain
  from its own in-memory `@tree` (`DoIt.Tasks.Progress`), not a fresh
  `Tasks.lineage/1` DB read. Every connected viewer must still converge on
  the same, correctly-averaged numbers as before — this pins that outcome
  from a second session's point of view.
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
    mate = user("mate")
    {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Rollup Test"})
    {:ok, _} = Initiatives.add_member(ini.id, mate.id, "editor")
    %{conn: conn, owner: owner, mate: mate, ini: ini}
  end

  test "a leaf progress edit broadcasts live — the whole ancestor chain re-averages in a second connected view",
       %{owner: owner, mate: mate, ini: ini} do
    # root -> A -> B -> {C, D}; root -> A -> E (three leaves total under A).
    a = new_task(owner, ini, %{"title" => "A"})
    b = new_task(owner, ini, %{"title" => "B", "parent_id" => a.id})

    c =
      new_task(owner, ini, %{"title" => "C (leaf)", "parent_id" => b.id, "manual_progress" => 0})

    _d =
      new_task(owner, ini, %{"title" => "D (leaf)", "parent_id" => b.id, "manual_progress" => 100})

    _e =
      new_task(owner, ini, %{"title" => "E (leaf)", "parent_id" => a.id, "manual_progress" => 10})

    {:ok, mate_view, _} = live(log_in(build_conn(), mate), ~p"/initiatives/#{ini.id}")

    # Initial roll-ups: B = avg(0,100) = 50; A = avg(0,100,10) = 37 (half-up).
    assert has_element?(mate_view, "#task-#{b.id} [data-task-progress='50']")
    assert has_element?(mate_view, "#task-#{a.id} [data-task-progress='37']")
    assert has_element?(mate_view, "[aria-label='Initiative progress: 37%']")

    # Someone else edits leaf C directly — only ONE {:task_updated, c.id}
    # broadcast fires; the mate's process must derive B's, A's, and the
    # header's new roll-ups itself, from its own in-memory tree, with no
    # per-ancestor broadcast to lean on.
    {:ok, _} = Tasks.update_task(c, owner, %{"manual_progress" => 60})

    assert has_element?(mate_view, "#task-#{c.id} [data-task-progress='60']")
    assert has_element?(mate_view, "#task-#{b.id} [data-task-progress='80']")
    assert has_element?(mate_view, "#task-#{a.id} [data-task-progress='57']")
    assert has_element?(mate_view, "[aria-label='Initiative progress: 57%']")
  end

  test "a completion-cascade flip broadcasts live — the parent's done-state and roll-up update in a second connected view",
       %{owner: owner, mate: mate, ini: ini} do
    parent = new_task(owner, ini, %{"title" => "Parent"})
    child = new_task(owner, ini, %{"title" => "Child (leaf)", "parent_id" => parent.id})

    {:ok, mate_view, _} = live(log_in(build_conn(), mate), ~p"/initiatives/#{ini.id}")

    refute has_element?(mate_view, "#task-#{parent.id} [data-done]")
    refute has_element?(mate_view, "#task-#{child.id} [data-done]")

    # A single-child completion cascades: two separate {:task_updated}
    # broadcasts land (the flipped leaf, then the now-fully-done parent) —
    # each is handled the same way as a plain edit, in the order it arrives.
    {:ok, _} = Tasks.toggle_complete(child, owner)

    assert has_element?(mate_view, "#task-#{child.id} [data-done]")
    assert has_element?(mate_view, "#task-#{parent.id} [data-done]")
    assert has_element?(mate_view, "#task-#{parent.id} [data-task-progress='100']")
  end

  test "the acting user's OWN completion toggle shows the flipped ancestor done in the same response — no stale-status revert",
       %{conn: conn, owner: owner, ini: ini} do
    parent = new_task(owner, ini, %{"title" => "Parent"})
    done_child = new_task(owner, ini, %{"title" => "Done child", "parent_id" => parent.id})
    {:ok, _} = Tasks.toggle_complete(done_child, owner)
    last_child = new_task(owner, ini, %{"title" => "Last open child", "parent_id" => parent.id})

    {:ok, view, _} = live(log_in(conn, owner), ~p"/initiatives/#{ini.id}")

    # One child still open, so the parent's OWN row isn't done yet.
    refute has_element?(view, "#task-#{parent.id} > [data-task-row][data-done]")

    # The acting user toggles the last open leaf. patch_task's confirming
    # render must carry the cascade's fresh ancestor status (Tasks.statuses_for/1),
    # not the stale in-memory copy — else the optimistic parent-done flip reverts
    # here until a later broadcast. The `>` combinator pins the parent's OWN row
    # so a done CHILD can't give a false pass.
    render_hook(view, "toggle_complete", %{"id" => to_string(last_child.id)})

    assert has_element?(view, "#task-#{last_child.id} > [data-task-row][data-done]")
    assert has_element?(view, "#task-#{parent.id} > [data-task-row][data-done]")
    assert has_element?(view, "#task-#{parent.id} > [data-task-row][data-task-progress='100']")
  end
end
