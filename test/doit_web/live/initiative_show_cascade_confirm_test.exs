defmodule DoItWeb.InitiativeShowCascadeConfirmTest do
  @moduledoc """
  Branch cascade confirm (UX_GUARDRAILS 6.5/6.6). The "complete / reopen this
  branch and all subtasks?" confirm now opens CLIENT-SIDE: checking a branch's
  box flips the row optimistically and opens #cascade-confirm itself (title +
  verb are client-known), holding the flip while it decides. Proceed re-pushes
  the cascade event, which the server simply commits.

  The server contract this asserts:

    * cascade_complete / cascade_incomplete commit straight through — no
      server-rendered #completion-confirm modal, no pending action left behind.

  The client confirm itself is JS (no e2e rig) — [Human]-verified.
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

  # A branch with two incomplete leaves.
  setup %{conn: conn} do
    owner = user("owner")
    {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Alpha"})

    branch = new_task(owner, ini, %{"title" => "Branch"})
    leaf_a = new_task(owner, ini, %{"title" => "leaf-a", "parent_id" => branch.id})
    leaf_b = new_task(owner, ini, %{"title" => "leaf-b", "parent_id" => branch.id})

    %{
      conn: log_in(conn, owner),
      owner: owner,
      ini: ini,
      branch: branch,
      leaf_a: leaf_a,
      leaf_b: leaf_b
    }
  end

  test "cascade_complete commits straight through — no modal, no pending", %{
    conn: conn,
    ini: ini,
    branch: branch,
    leaf_a: leaf_a,
    leaf_b: leaf_b
  } do
    {:ok, view, _html} = live(conn, ~p"/initiatives/#{ini.id}")

    render_hook(view, "cascade_complete", %{"id" => to_string(branch.id)})

    # No server confirm modal was raised; the cascade landed on the whole branch.
    refute has_element?(view, "#completion-confirm")
    assert Tasks.get_task!(branch.id).status == "done"
    assert Tasks.get_task!(leaf_a.id).status == "done"
    assert Tasks.get_task!(leaf_b.id).status == "done"
  end

  test "cascade_incomplete reopens the whole branch with no modal", %{
    conn: conn,
    owner: owner,
    ini: ini,
    branch: branch,
    leaf_a: leaf_a,
    leaf_b: leaf_b
  } do
    {:ok, _} = Tasks.cascade_complete(Tasks.get_task!(branch.id), owner)
    assert Tasks.get_task!(branch.id).status == "done"

    {:ok, view, _html} = live(conn, ~p"/initiatives/#{ini.id}")

    render_hook(view, "cascade_incomplete", %{"id" => to_string(branch.id)})

    refute has_element?(view, "#completion-confirm")
    assert Tasks.get_task!(branch.id).status == "open"
    assert Tasks.get_task!(leaf_a.id).status == "open"
    assert Tasks.get_task!(leaf_b.id).status == "open"
  end
end
