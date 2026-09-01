defmodule DoItWeb.PasswordChangeRequiredTest do
  @moduledoc """
  A flagged user (`password_change_required`) is redirected to /account from
  any other authenticated LiveView, but can still reach /account itself and
  clear the flag there by successfully changing their password.
  """
  use DoItWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DoIt.Accounts

  defp user(name) do
    {:ok, u} =
      Accounts.register_user(%{
        "email" => "#{name}-#{System.unique_integer([:positive])}@example.com",
        "username" => "#{name}-#{System.unique_integer([:positive])}",
        "name" => String.capitalize(name),
        "password" => "old-password"
      })

    u
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, user.id)
  end

  test "an unflagged user mounts an authenticated content route normally", %{conn: conn} do
    me = user("me")
    conn = log_in(conn, me)

    assert {:ok, _view, _html} = live(conn, ~p"/assigned")
    assert {:ok, _view, _html} = live(conn, ~p"/initiatives")
  end

  test "a flagged user is redirected off content routes but can reach /account", %{conn: conn} do
    me = user("me")
    {:ok, me} = Accounts.require_password_change(me)
    conn = log_in(conn, me)

    assert {:error, {:redirect, %{to: "/account"} = redirect}} = live(conn, ~p"/assigned")
    assert redirect.flash["error"] =~ "must change your password"

    assert {:error, {:redirect, %{to: "/account"}}} = live(conn, ~p"/initiatives")

    assert {:ok, _view, _html} = live(conn, ~p"/account")
  end

  test "successfully changing the password clears the flag and unlocks content routes", %{
    conn: conn
  } do
    me = user("me")
    {:ok, me} = Accounts.require_password_change(me)
    conn = log_in(conn, me)

    {:ok, view, _html} = live(conn, ~p"/account")

    view
    |> element("#password-form")
    |> render_submit(%{
      "user" => %{
        "current_password" => "old-password",
        "password" => "new-password-9",
        "password_confirmation" => "new-password-9"
      }
    })

    refute Accounts.get_user(me.id).password_change_required
    assert {:ok, _view, _html} = live(conn, ~p"/assigned")
  end
end
