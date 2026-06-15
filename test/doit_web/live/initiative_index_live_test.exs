defmodule DoItWeb.InitiativeIndexLiveTest do
  @moduledoc """
  Index-sort persistence (m02.04 §2.6): the existing sort control writes
  through to the account — mode + per-mode reverse on the prefs record,
  manual order on the membership rows — so a fresh mount restores it.
  """
  use DoItWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DoIt.{Accounts, Initiatives}

  defp register_and_log_in(conn) do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "idx-#{System.unique_integer([:positive])}@example.com",
        "username" => "idx-#{System.unique_integer([:positive])}",
        "name" => "Index User",
        "password" => "password123"
      })

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    {conn, user}
  end

  defp create!(user, name) do
    {:ok, initiative} = Initiatives.create_initiative(user, %{"name" => name})
    initiative
  end

  # On wide screens the page lists initiatives twice — the ultrawide left rail
  # (chrome, in `Layouts.app`) and the main card list. Sort order is a property
  # of the main list, so scope the position check to the `#initiatives`
  # container (everything after the rail).
  defp html_order(html, names) do
    [_rail_and_chrome, list_html] = String.split(html, ~s(id="initiatives"), parts: 2)
    Enum.sort_by(names, &elem(:binary.match(list_html, &1), 0))
  end

  test "mode + per-mode reverse persist to prefs and seed the next mount", %{conn: conn} do
    {conn, user} = register_and_log_in(conn)
    for n <- ["Bravo", "Alpha", "Charlie"], do: create!(user, n)

    {:ok, view, _} = live(conn, ~p"/initiatives")
    render_click(view, "apply_sort", %{"mode" => "name", "reverse" => true})

    prefs = Accounts.get_preferences(user)
    assert prefs.index_sort_mode == "name"
    assert prefs.index_sort_reverse_by_mode == %{"name" => true}

    {:ok, view, html} = live(conn, ~p"/initiatives")
    assert html_order(html, ["Charlie", "Bravo", "Alpha"]) == ["Charlie", "Bravo", "Alpha"]
    assert has_element?(view, ~s(#initiative-sort-mode option[value="name"][selected]))
    assert has_element?(view, ~s(#initiative-sort input[name="reverse"][checked]))

    # Reverse memory is per mode: turning it off for "updated" leaves "name" reversed.
    render_click(view, "apply_sort", %{"mode" => "updated", "reverse" => false})

    assert Accounts.get_preferences(user).index_sort_reverse_by_mode ==
             %{"name" => true, "updated" => false}
  end

  test "manual drag order lands on the membership rows and survives a remount", %{conn: conn} do
    {conn, user} = register_and_log_in(conn)
    [b, a, c] = for n <- ["Bravo", "Alpha", "Charlie"], do: create!(user, n)

    {:ok, view, _} = live(conn, ~p"/initiatives")

    render_click(view, "apply_sort", %{
      "mode" => "manual",
      "reverse" => false,
      "order" => [to_string(c.id), to_string(a.id), to_string(b.id)]
    })

    {:ok, _view, html} = live(conn, ~p"/initiatives")
    assert html_order(html, ["Charlie", "Alpha", "Bravo"]) == ["Charlie", "Alpha", "Bravo"]
  end
end
