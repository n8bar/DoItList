defmodule DoItWeb.InitiativeShowDeferredLoadTest do
  @moduledoc """
  Deferred non-critical loads (perf fix): the connected mount renders the tree
  synchronously but pushes the undo/redo labels and the cross-Initiative
  Collaborators rail off the critical path into a `:after_mount` message, so the
  page is interactive the instant the tree paints. These assert the deferred
  assigns DO get filled after the connected mount settles.
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

  setup %{conn: conn} do
    owner = user("owner")
    {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Alpha"})
    %{conn: log_in(conn, owner), owner: owner, ini: ini}
  end

  test "undo label is filled after mount (button enabled once :after_mount runs)", %{
    conn: conn,
    owner: owner,
    ini: ini
  } do
    # An undoable event must exist for the toolbar label to be non-nil. Creating
    # a task records a `:created` event — the newest undoable op on the stack.
    {:ok, _t} =
      Tasks.create_task(owner, %{
        "title" => "Branch",
        "initiative_id" => ini.id,
        "parent_id" => ini.root_task_id
      })

    {:ok, view, _html} = live(conn, ~p"/initiatives/#{ini.id}")

    # has_element?/2 forces a sync round-trip, flushing the :after_mount message
    # the connected mount sent to itself. The undo button starts disabled
    # (label nil) and must be ENABLED once :after_mount fills the undo label.
    refute has_element?(view, "#undo-button[disabled]")
    assert has_element?(view, "#undo-button:not([disabled])")
    # The filled label names the action (a created task → "create …").
    assert has_element?(view, "#undo-button[title^='Undo: create']")
  end

  test "collaborators rail is filled after mount", %{conn: conn, owner: owner, ini: ini} do
    # A second member of the same Initiative becomes a live collaborator of the
    # owner, so the owner's deferred Collaborators rail should list their row.
    other = user("other")
    {:ok, _} = Initiatives.add_member(ini.id, other.id, "editor", owner)

    {:ok, view, _html} = live(conn, ~p"/initiatives/#{ini.id}")

    # Flush :after_mount, then the deferred rail_collaborators must include the
    # other member's row (rendered with a stable per-user DOM id).
    _ = render(view)
    assert has_element?(view, "#collabrow-#{other.id}")
  end
end
