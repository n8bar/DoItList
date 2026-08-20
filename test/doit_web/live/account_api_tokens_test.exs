defmodule DoItWeb.AccountApiTokensTest do
  @moduledoc """
  The account page's "API tokens" section (m03.01 worklist 1.2): mint reveals
  the plaintext once, the token lists, dismissing hides the plaintext for good,
  and revoke removes it. Plus the agent-connect panel (m03.04 2.1.1.2):
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

  test "minting clears the label box; a blank label mints nothing", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/account")

    # The typed value is tracked via phx-change, so the post-mint reset
    # actually diffs the input back to empty (the bug: it kept its text).
    view
    |> form("#api-token-form", api_token: %{label: "My CLI"})
    |> render_change()

    view
    |> form("#api-token-form", api_token: %{label: "My CLI"})
    |> render_submit()

    assert [%{label: "My CLI"}] = Accounts.list_api_tokens(user)

    refute view |> element("#api-token-form input[name='api_token[label]']") |> render() =~
             "My CLI"

    # Blank label: server rejects (the browser's `required` gates it client-side).
    view
    |> form("#api-token-form", api_token: %{label: "   "})
    |> render_submit()

    assert render(view) =~ "Couldn&#39;t mint token."
    assert [_only_the_first] = Accounts.list_api_tokens(user)
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

  test "connect panel carries both shell variants and the toggle (m03.04 2.1.2.1)", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/account")

    view
    |> form("#api-token-form", api_token: %{label: "Agent"})
    |> render_submit()

    # Toggle and both panes are in the DOM together — switching is
    # client-side visibility, no round-trip.
    assert has_element?(view, "#connect-shell-toggle")
    assert has_element?(view, "#connect-shell-posix")
    assert has_element?(view, "#connect-shell-powershell")
    assert has_element?(view, "#connect-pastes-posix")
    assert has_element?(view, "#connect-pastes-powershell")

    # The PowerShell pane has its own per-client pastes and copy buttons.
    for slug <- ["claude-code", "codex", "hermes"] do
      assert has_element?(view, "#connect-cmd-#{slug}-ps")
      assert has_element?(view, "#connect-copy-#{slug}-ps")
    end

    # And carries the PowerShell wording, not bash's.
    codex_ps = view |> element("#connect-cmd-codex-ps") |> render()
    assert codex_ps =~ "$env:DOITLIST_API_TOKEN"
    assert codex_ps =~ "setx DOITLIST_API_TOKEN"
    refute codex_ps =~ "export"
    assert view |> element("#connect-cmd-hermes-ps") |> render() =~ "-Encoding utf8"
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

  describe "repo-marker panel (m03.04 2.1.1.4)" do
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

    test "reload brings in post-mount initiatives and keeps the selection", %{
      conn: conn,
      user: user
    } do
      {:ok, _a} = Initiatives.create_initiative(user, %{"name" => "Alpha"}, agent_access: true)
      {:ok, _b} = Initiatives.create_initiative(user, %{"name" => "Beta"}, agent_access: true)
      [_first, second] = Initiatives.list_agent_accessible_initiatives(user)

      {:ok, view, _html} = live(conn, ~p"/account")

      view
      |> form("#repo-marker-form", %{"initiative_id" => to_string(second.id)})
      |> render_change()

      {:ok, _c} = Initiatives.create_initiative(user, %{"name" => "Gamma"}, agent_access: true)
      refute has_element?(view, "#repo-marker-initiative option", "Gamma")

      view |> element("#repo-marker-reload") |> render_click()

      assert has_element?(view, "#repo-marker-initiative option", "Gamma")
      # The pre-reload selection survives the refetch.
      snippet = view |> element("#repo-marker-snippet") |> render()
      assert snippet =~ "/initiatives/#{second.id}"
    end

    test "reload replaces the empty state once an initiative is AI-enabled", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/account")
      assert has_element?(view, "#repo-marker-empty")
      assert has_element?(view, "#repo-marker-reload")

      {:ok, _a} = Initiatives.create_initiative(user, %{"name" => "Alpha"}, agent_access: true)

      view |> element("#repo-marker-reload") |> render_click()

      refute has_element?(view, "#repo-marker-empty")
      assert has_element?(view, "#repo-marker-initiative option", "Alpha")
      assert has_element?(view, "#repo-marker-snippet")
    end
  end
end
