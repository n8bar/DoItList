defmodule DoItWeb.InitiativeShowUpdateTaskTargetTest do
  @moduledoc """
  update_task self-targeting (WL4.2.2, dead-window Defect 2). The pane's two
  update_task forms carry no task id, so natively the server applies them to its
  loaded selection. A dead-window pane edit, though, flushes on connect BEFORE
  the .TaskKeys selection replay lands — so the client captures the task the edit
  was made against (DoitState.selectedId) into the payload. Server contract:

    * update_task with an explicit "id" → applies to THAT task (guarded to this
      initiative's tree), regardless of / ahead of any server-side selection.
    * update_task without "id" → applies to selected_task (native pane contract).
    * a stale / foreign id → falls back to selected_task (never the wrong tree).

  The capture itself is JS (no e2e rig) — [Human]-verified.
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
    task_a = new_task(owner, ini, %{"title" => "A"})
    task_b = new_task(owner, ini, %{"title" => "B"})

    # A task in a SEPARATE initiative — the foreign-id guard target.
    {:ok, other_ini} = Initiatives.create_initiative(owner, %{"name" => "Beta"})
    foreign = new_task(owner, other_ini, %{"title" => "Foreign"})

    %{conn: log_in(conn, owner), ini: ini, task_a: task_a, task_b: task_b, foreign: foreign}
  end

  test "an explicit id lands on that task with NO server-side selection (flush-before-select)",
       %{conn: conn, ini: ini, task_a: task_a, task_b: task_b} do
    {:ok, view, _html} = live(conn, ~p"/initiatives/#{ini.id}")

    # No select_task has been replayed yet — mirrors the dead-window flush order.
    render_hook(view, "update_task", %{
      "task" => %{"title" => "B-renamed"},
      "id" => to_string(task_b.id)
    })

    assert Tasks.get_task!(task_b.id).title == "B-renamed"
    assert Tasks.get_task!(task_a.id).title == "A"
  end

  test "an explicit id targets its own task even when a DIFFERENT task is selected",
       %{conn: conn, ini: ini, task_a: task_a, task_b: task_b} do
    {:ok, view, _html} = live(conn, ~p"/initiatives/#{ini.id}")

    # Select A, then replay an edit captured against B → lands on B, not A.
    render_hook(view, "select_task", %{"id" => to_string(task_a.id)})
    render_hook(view, "update_task", %{"task" => %{"title" => "B-edit"}, "id" => to_string(task_b.id)})
    assert Tasks.get_task!(task_b.id).title == "B-edit"
    assert Tasks.get_task!(task_a.id).title == "A"

    # And an edit captured against A lands on A (its own task).
    render_hook(view, "update_task", %{"task" => %{"title" => "A-edit"}, "id" => to_string(task_a.id)})
    assert Tasks.get_task!(task_a.id).title == "A-edit"
    assert Tasks.get_task!(task_b.id).title == "B-edit"
  end

  test "no id falls back to the loaded selection (native pane contract)",
       %{conn: conn, ini: ini, task_a: task_a, task_b: task_b} do
    {:ok, view, _html} = live(conn, ~p"/initiatives/#{ini.id}")

    render_hook(view, "select_task", %{"id" => to_string(task_a.id)})
    render_hook(view, "update_task", %{"task" => %{"title" => "A-native"}})
    assert Tasks.get_task!(task_a.id).title == "A-native"
    assert Tasks.get_task!(task_b.id).title == "B"
  end

  test "a foreign-initiative id is rejected and falls back to the selection",
       %{conn: conn, ini: ini, task_a: task_a, foreign: foreign} do
    {:ok, view, _html} = live(conn, ~p"/initiatives/#{ini.id}")

    render_hook(view, "select_task", %{"id" => to_string(task_a.id)})
    render_hook(view, "update_task", %{"task" => %{"title" => "fallback"}, "id" => to_string(foreign.id)})

    # The foreign task is untouched; the edit fell back to the selected task A.
    assert Tasks.get_task!(foreign.id).title == "Foreign"
    assert Tasks.get_task!(task_a.id).title == "fallback"
  end
end
