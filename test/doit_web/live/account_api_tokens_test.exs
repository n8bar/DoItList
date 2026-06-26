defmodule DoItWeb.AccountApiTokensTest do
  @moduledoc """
  The account page's "API tokens" section (m03.01 worklist 1.2): mint reveals
  the plaintext once, the token lists, dismissing hides the plaintext for good,
  and revoke removes it.
  """
  use DoItWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DoIt.Accounts

  defp user do
    {:ok, u} =
      Accounts.register_user(%{
        "email" => "acct-#{System.unique_integer([:positive])}@example.com",
        "username" => "acct-#{System.unique_integer([:positive])}",
        "name" => "Acct User",
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
    user = user()
    %{conn: log_in(conn, user), user: user}
  end

  test "minting reveals the plaintext once and lists the token", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/account")

    refute has_element?(view, "#api-token-reveal")

    view
    |> form("#api-token-form", api_token: %{label: "My CLI"})
    |> render_submit()

    # The one-time reveal shows the plaintext (a doit_pat_ token).
    assert has_element?(view, "#api-token-reveal")
    assert render(view) =~ "doit_pat_"

    # It now lists under the user's tokens.
    [token] = Accounts.list_api_tokens(user)
    assert has_element?(view, "#api-token-#{token.id}")
    assert render(view) =~ "My CLI"

    # Dismissing the reveal hides the plaintext for good.
    view |> element("#api-token-dismiss") |> render_click()
    refute has_element?(view, "#api-token-reveal")
    refute render(view) =~ "doit_pat_"
  end

  test "the plaintext is not re-shown on a fresh mount", %{conn: conn, user: user} do
    {:ok, _} = Accounts.mint_api_token(user, "Existing")

    {:ok, view, _html} = live(conn, ~p"/account")

    refute has_element?(view, "#api-token-reveal")
    refute render(view) =~ "doit_pat_"
    assert render(view) =~ "Existing"
  end

  test "revoking removes the token from the list", %{conn: conn, user: user} do
    {:ok, {_pt, token}} = Accounts.mint_api_token(user, "Throwaway")

    {:ok, view, _html} = live(conn, ~p"/account")
    assert has_element?(view, "#api-token-#{token.id}")

    view |> element("#revoke-api-token-#{token.id}") |> render_click()

    refute has_element?(view, "#api-token-#{token.id}")
    assert Accounts.list_api_tokens(user) == []
  end
end
