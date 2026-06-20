defmodule DoItWeb.NotificationsLiveTest do
  @moduledoc """
  The nav notification dot + flyout (m02.08 worklist 2 items 2.3–2.5), wired
  globally via the `DoItWeb.UserAuth` on_mount hook: the red dot renders from a
  server-derived assign, a live push (per-user PubSub) raises it without a
  reload, and the menu's mark-read gesture clears it.
  """
  use DoItWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DoIt.{Accounts, Initiatives, Notifications}

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
    me = user("me")
    {:ok, ini} = Initiatives.create_initiative(me, %{"name" => "Alpha"})
    %{conn: log_in(conn, me), me: me, ini: ini}
  end

  test "no dot when there are no unread notifications", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/initiatives")
    refute has_element?(view, "[aria-label='Unread notifications']")
  end

  test "an existing unread notification renders the dot and a flyout entry", %{conn: conn, me: me} do
    {:ok, _} =
      Notifications.create(me.id, "member_added", %{initiative_id: 1, actor_name: "Boss"})

    {:ok, view, _html} = live(conn, ~p"/initiatives")
    assert has_element?(view, "[aria-label='Unread notifications']")
    assert has_element?(view, "#notifications-list-desktop", "Boss")
  end

  test "a live push raises the dot without a reload", %{conn: conn, me: me} do
    {:ok, view, _html} = live(conn, ~p"/initiatives")
    refute has_element?(view, "[aria-label='Unread notifications']")

    # Simulate another user's action dropping a notification on us.
    {:ok, _} = Notifications.create(me.id, "assigned", %{initiative_id: 1, task_id: 2})

    # The on_mount handle_info hook re-renders the layout from the fresh count.
    assert render(view) =~ "Unread notifications"
    assert has_element?(view, "[aria-label='Unread notifications']")
  end

  test "the mark-read gesture clears the dot", %{conn: conn, me: me} do
    {:ok, _} = Notifications.create(me.id, "member_added", %{initiative_id: 1})

    {:ok, view, _html} = live(conn, ~p"/initiatives")
    assert has_element?(view, "[aria-label='Unread notifications']")

    render_click(view, "mark_notifications_read", %{})
    refute has_element?(view, "[aria-label='Unread notifications']")
    assert Notifications.unread_count(me) == 0
  end
end
