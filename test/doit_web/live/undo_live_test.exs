defmodule DoItWeb.UndoLiveTest do
  @moduledoc """
  m02.06 items 4/5 — the undo/redo toolbar + handlers in the Initiative view.
  The buttons reflect stack availability; the handlers reverse / re-apply and
  flash the outcome.
  """
  use DoItWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DoIt.{Accounts, Initiatives, Tasks}

  defp register_and_log_in(conn) do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "undo-#{System.unique_integer([:positive])}@example.com",
        "username" => "undo-#{System.unique_integer([:positive])}",
        "name" => "Undo User",
        "password" => "password123"
      })

    {Plug.Test.init_test_session(conn, %{}) |> Plug.Conn.put_session(:user_id, user.id), user}
  end

  setup %{conn: conn} do
    {conn, user} = register_and_log_in(conn)
    {:ok, initiative} = Initiatives.create_initiative(user, %{"name" => "Init"})

    {:ok, t} =
      Tasks.create_task(user, %{
        "initiative_id" => initiative.id,
        "parent_id" => initiative.root_task_id,
        "title" => "v0"
      })

    %{conn: conn, user: user, initiative: initiative, t: t}
  end

  test "toolbar reflects the stack and the handlers round-trip", %{
    conn: conn,
    initiative: initiative,
    t: t
  } do
    {:ok, view, _} = live(conn, ~p"/initiatives/#{initiative.id}")

    # Creating the task left an undoable event; nothing to redo yet.
    refute has_element?(view, "#undo-button[disabled]")
    assert has_element?(view, "#redo-button[disabled]")

    # Rename through the editor, then undo it.
    render_hook(view, "select_task", %{"id" => Integer.to_string(t.id)})
    render_submit(view, "update_task", %{"task" => %{"title" => "v1"}})
    assert Tasks.get_task!(t.id).title == "v1"

    html = render_click(view, "undo", %{})
    assert Tasks.get_task!(t.id).title == "v0"
    assert html =~ "Undid rename"
    refute has_element?(view, "#redo-button[disabled]")

    html = render_click(view, "redo", %{})
    assert Tasks.get_task!(t.id).title == "v1"
    assert html =~ "Redid rename"
  end

  test "undo with an empty stack flashes nothing-to-undo", %{conn: conn, initiative: initiative, t: t} do
    {:ok, view, _} = live(conn, ~p"/initiatives/#{initiative.id}")

    # Undo the only event (the task create), then there's nothing left.
    render_click(view, "undo", %{})
    assert Tasks.get_task!(t.id).deleted_at

    html = render_click(view, "undo", %{})
    assert html =~ "Nothing to undo"
    assert has_element?(view, "#undo-button[disabled]")
  end
end
