defmodule DoItWeb.InitiativeShowMoveConfirmTest do
  @moduledoc """
  Completion-flip confirm on a move (UX_GUARDRAILS 6.5). The client predicts the
  flip from the DOM and opens the confirm itself, then re-sends move_task with
  `confirmed: true`. The server contract:

    * move_task on a flip scenario WITHOUT `confirmed` → gates: replies
      committed:false and renders the #completion-confirm modal (the
      authoritative backstop for a move the client didn't predict).
    * move_task with `confirmed: true` → commits straight through, no modal.

  The client prediction itself is JS (no e2e rig) — [Human]-verified.
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

  # Scenario 2 (complete): root_a holds a done child + an incomplete child;
  # moving the incomplete child out to root_b leaves root_a all-done → it flips.
  setup %{conn: conn} do
    owner = user("owner")
    {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Alpha"})

    root_a = new_task(owner, ini, %{"title" => "A-root"})
    _done = new_task(owner, ini, %{"title" => "done-child", "parent_id" => root_a.id, "status" => "done"})
    incomplete = new_task(owner, ini, %{"title" => "incomplete-child", "parent_id" => root_a.id, "manual_progress" => 50})
    root_b = new_task(owner, ini, %{"title" => "B-root"})

    # Sanity: root_a is still open (it has the incomplete child).
    assert Tasks.get_task!(root_a.id).status == "open"

    %{conn: log_in(conn, owner), ini: ini, root_a: root_a, root_b: root_b, incomplete: incomplete}
  end

  test "a flip move without confirmed gates the confirm and persists nothing", %{
    conn: conn,
    ini: ini,
    root_a: root_a,
    root_b: root_b,
    incomplete: incomplete
  } do
    {:ok, view, _html} = live(conn, ~p"/initiatives/#{ini.id}")

    render_hook(view, "move_task", %{"task_id" => to_string(incomplete.id), "parent_id" => to_string(root_b.id)})

    # The authoritative backstop fired: the modal is up and nothing committed.
    assert has_element?(view, "#completion-confirm")
    assert Tasks.get_task!(incomplete.id).parent_id == root_a.id
    assert Tasks.get_task!(root_a.id).status == "open"
  end

  test "confirmed: true commits the flip with no modal (client already confirmed)", %{
    conn: conn,
    ini: ini,
    root_a: root_a,
    root_b: root_b,
    incomplete: incomplete
  } do
    {:ok, view, _html} = live(conn, ~p"/initiatives/#{ini.id}")

    render_hook(view, "move_task", %{
      "task_id" => to_string(incomplete.id),
      "parent_id" => to_string(root_b.id),
      "confirmed" => true
    })

    # Committed straight through: no gate, the move stuck, root_a flipped done.
    refute has_element?(view, "#completion-confirm")
    assert Tasks.get_task!(incomplete.id).parent_id == root_b.id
    assert Tasks.get_task!(root_a.id).status == "done"
  end
end
