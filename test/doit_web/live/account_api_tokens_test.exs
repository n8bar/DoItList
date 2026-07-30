defmodule DoItWeb.AccountApiTokensTest do
  @moduledoc """
  The account page's "API tokens" section (m03.01 worklist 1.2): mint reveals
  the plaintext once, the token lists, dismissing hides the plaintext for good,
  and revoke removes it. Plus the agent-connect panel (m03.04 item 24.2):
  per-client pastes riding the one-time reveal, gone with the dismiss.
  """
  use DoItWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DoIt.{Accounts, Initiatives}

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

  test "minting shows the connect panel; dismissing removes it with the reveal", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/account")

    refute has_element?(view, "#agent-connect-panel")

    view
    |> form("#api-token-form", api_token: %{label: "Agent"})
    |> render_submit()

    assert has_element?(view, "#agent-connect-panel")
    assert has_element?(view, "#connect-copy-claude-code")
    assert has_element?(view, "#connect-copy-codex")
    assert has_element?(view, "#connect-copy-hermes")

    # Self-contained pastes: the minted plaintext and the endpoint URL are in
    # the panel itself — no assembly by the reader.
    [plaintext] = Regex.run(~r/doit_pat_[A-Za-z0-9_-]+/, render(view))
    panel = view |> element("#agent-connect-panel") |> render()
    assert panel =~ plaintext
    assert panel =~ DoItWeb.AgentConnect.mcp_url()

    view |> element("#api-token-dismiss") |> render_click()
    refute has_element?(view, "#agent-connect-panel")
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

  describe "repo-marker panel (m03.04 item 24.4)" do
    test "lists only agent-accessible initiatives and composes the snippet", %{
      conn: conn,
      user: user
    } do
      {:ok, _a} = Initiatives.create_initiative(user, %{"name" => "Alpha"}, agent_access: true)
      {:ok, _b} = Initiatives.create_initiative(user, %{"name" => "Beta"}, agent_access: true)
      {:ok, _off} = Initiatives.create_initiative(user, %{"name" => "Private Notes"})

      # The panel's default is the first entry of the context list.
      [first, second] = Initiatives.list_agent_accessible_initiatives(user)

      {:ok, view, _html} = live(conn, ~p"/account")

      assert has_element?(view, "#repo-marker-panel")
      assert has_element?(view, "#repo-marker-copy")
      assert has_element?(view, "#repo-marker-initiative option", first.name)
      assert has_element?(view, "#repo-marker-initiative option", second.name)

      # Exactly the two accessible names — the flagged-off one is absent.
      select_html = view |> element("#repo-marker-initiative") |> render()
      assert length(Regex.scan(~r/<option/, select_html)) == 2
      panel = view |> element("#repo-marker-panel") |> render()
      refute panel =~ "Private Notes"

      snippet = view |> element("#repo-marker-snippet") |> render()
      assert snippet =~ first.name
      assert snippet =~ "/initiatives/#{first.id}"
    end

    test "changing the select swaps the snippet to the other initiative", %{
      conn: conn,
      user: user
    } do
      {:ok, _a} = Initiatives.create_initiative(user, %{"name" => "Alpha"}, agent_access: true)
      {:ok, _b} = Initiatives.create_initiative(user, %{"name" => "Beta"}, agent_access: true)
      [first, second] = Initiatives.list_agent_accessible_initiatives(user)

      {:ok, view, _html} = live(conn, ~p"/account")

      view
      |> form("#repo-marker-form", %{"initiative_id" => to_string(second.id)})
      |> render_change()

      snippet = view |> element("#repo-marker-snippet") |> render()
      assert snippet =~ second.name
      assert snippet =~ "/initiatives/#{second.id}"
      refute snippet =~ "/initiatives/#{first.id}"
    end

    test "with no agent-accessible initiatives the empty state renders", %{
      conn: conn,
      user: user
    } do
      # An Initiative exists, but agent access is off — still the empty state.
      {:ok, _off} = Initiatives.create_initiative(user, %{"name" => "Private Notes"})

      {:ok, view, _html} = live(conn, ~p"/account")

      assert has_element?(view, "#repo-marker-panel")
      assert has_element?(view, "#repo-marker-empty")
      refute has_element?(view, "#repo-marker-initiative")
      refute has_element?(view, "#repo-marker-snippet")
    end
  end
end
