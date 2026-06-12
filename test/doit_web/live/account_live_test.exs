defmodule DoItWeb.AccountLiveTest do
  @moduledoc """
  Tests for the Account Details page (M02 Arc 4).
  """
  use DoItWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DoIt.Accounts

  defp register_and_log_in(conn) do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "account-#{System.unique_integer([:positive])}@example.com",
        "username" => "account-#{System.unique_integer([:positive])}",
        "name" => "Account User",
        "password" => "password123"
      })

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    {conn, user}
  end

  test "redirects anonymous visitors to log in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(conn, ~p"/account")
  end

  test "shows the current user's profile details", %{conn: conn} do
    {conn, user} = register_and_log_in(conn)

    {:ok, view, _html} = live(conn, ~p"/account")

    assert has_element?(view, "#account-profile")
    assert render(view) =~ user.email
    assert render(view) =~ user.name
  end

  describe "display name editing (§1.6)" do
    test "saves a new display name and rejects a blank one", %{conn: conn} do
      {conn, user} = register_and_log_in(conn)
      {:ok, view, _html} = live(conn, ~p"/account")

      view
      |> form("#profile-form", user: %{name: "Renamed Person"})
      |> render_submit()

      assert render(view) =~ "Profile updated."
      assert Accounts.get_user(user.id).name == "Renamed Person"

      blank =
        view
        |> form("#profile-form", user: %{name: ""})
        |> render_submit()

      assert blank =~ "can&#39;t be blank"
      assert Accounts.get_user(user.id).name == "Renamed Person"
    end
  end

  describe "change email (§1.8)" do
    test "saves a new email, downcased, and rejects a taken one", %{conn: conn} do
      {other_conn, other} = register_and_log_in(conn)
      {:ok, _other_view, _} = live(other_conn, ~p"/account")

      {conn, user} = register_and_log_in(conn)
      {:ok, view, _html} = live(conn, ~p"/account")

      taken =
        view
        |> form("#profile-form", user: %{email: other.email})
        |> render_change()

      assert taken =~ "has already been taken"

      view
      |> form("#profile-form", user: %{email: "Fresh-Address@Example.com"})
      |> render_submit()

      assert render(view) =~ "Profile updated."
      assert Accounts.get_user(user.id).email == "fresh-address@example.com"
    end
  end

  describe "change password (§1.7)" do
    test "changes the password through the form", %{conn: conn} do
      {conn, user} = register_and_log_in(conn)
      {:ok, view, _html} = live(conn, ~p"/account")

      wrong =
        view
        |> form("#password-form",
          user: %{
            current_password: "nope",
            password: "brand-new-pass",
            password_confirmation: "brand-new-pass"
          }
        )
        |> render_submit()

      assert wrong =~ "is not your current password"

      view
      |> form("#password-form",
        user: %{
          current_password: "password123",
          password: "brand-new-pass",
          password_confirmation: "brand-new-pass"
        }
      )
      |> render_submit()

      assert render(view) =~ "Password updated."
      assert {:ok, _} = Accounts.authenticate(user.email, "brand-new-pass")
    end
  end

  describe "username editing (§1.3)" do
    test "live-validates format and uniqueness as you type", %{conn: conn} do
      {other_conn, _other} = register_and_log_in(conn)
      {:ok, other_view, _} = live(other_conn, ~p"/account")

      other_view
      |> form("#username-form", user: %{username: "taken-name"})
      |> render_submit()

      {conn, _user} = register_and_log_in(conn)
      {:ok, view, _html} = live(conn, ~p"/account")

      bad_format =
        view
        |> form("#username-form", user: %{username: "no spaces!"})
        |> render_change()

      assert bad_format =~ "use letters, numbers"

      collision =
        view
        |> form("#username-form", user: %{username: "Taken-Name"})
        |> render_change()

      assert collision =~ "has already been taken"
    end

    test "saves a valid username, normalized", %{conn: conn} do
      {conn, user} = register_and_log_in(conn)
      {:ok, view, _html} = live(conn, ~p"/account")

      view
      |> form("#username-form", user: %{username: "  New_Handle  "})
      |> render_submit()

      assert render(view) =~ "Username updated."
      assert Accounts.get_user(user.id).username == "new_handle"
    end
  end
end
