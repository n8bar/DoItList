defmodule DoItWeb.AccountConnectUrlTest do
  @moduledoc """
  m03.04 6.17: the connect panel warns when the URL its pastes are about to
  carry is one every client refuses — plain http off loopback — and stays quiet
  for https and for loopback. 6.20: a second notice for the MCP address the
  panel composes onto an origin nothing promises to answer. `async: false`:
  flips the endpoint's public URL and the MCP env, both global.
  """
  use DoItWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DoIt.Accounts

  setup %{conn: conn} do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "connect-#{System.unique_integer([:positive])}@example.com",
        "username" => "connect-#{System.unique_integer([:positive])}",
        "name" => "Connect User",
        "password" => "password123"
      })

    {:ok, prev_endpoint} = Application.fetch_env(:doit, DoItWeb.Endpoint)
    prev_mcp_url = Application.fetch_env(:doit, :mcp_public_url)
    prev_mcp_port = Application.fetch_env(:doit, :mcp_public_port)

    on_exit(fn ->
      restore_env(:mcp_public_url, prev_mcp_url)
      restore_env(:mcp_public_port, prev_mcp_port)
      Application.put_env(:doit, DoItWeb.Endpoint, prev_endpoint)
      DoItWeb.Endpoint.config_change([{DoItWeb.Endpoint, prev_endpoint}], [])
    end)

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    %{conn: conn}
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:doit, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:doit, key)

  defp put_public_url(url) do
    config = Keyword.put(Application.get_env(:doit, DoItWeb.Endpoint), :url, url)
    Application.put_env(:doit, DoItWeb.Endpoint, config)
    DoItWeb.Endpoint.config_change([{DoItWeb.Endpoint, config}], [])
  end

  defp mint(conn) do
    {:ok, view, _html} = live(conn, ~p"/account")

    view
    |> form("#api-token-form", api_token: %{label: "Agent"})
    |> render_submit()

    view
  end

  # The composed MCP address: no override, the agent port alongside whatever
  # public URL the test sets.
  defp compose_mcp_url do
    Application.delete_env(:doit, :mcp_public_url)
    Application.put_env(:doit, :mcp_public_port, 4004)
  end

  test "a plain-http LAN URL warns, naming the URL and what to set", %{conn: conn} do
    put_public_url(scheme: "http", host: "192.168.68.31", port: 4000)
    compose_mcp_url()

    view = mint(conn)

    assert has_element?(view, "#connect-url-warning")

    warning = view |> element("#connect-url-warning") |> render()
    assert warning =~ "http://192.168.68.31:4000"
    assert warning =~ "which agent clients refuse"
    assert warning =~ "plain http works only on localhost"
    assert warning =~ "PUBLIC_SCHEME, PUBLIC_HOST, PUBLIC_PORT"

    # 6.20: both notices stand on their own — the scheme is one problem, the
    # composed agent port another, and this instance has both.
    assert has_element?(view, "#connect-mcp-url-warning")
  end

  test "an https public URL raises no warning", %{conn: conn} do
    put_public_url(scheme: "https", host: "doitlist.example.com", port: 443)
    Application.put_env(:doit, :mcp_public_url, "https://doitlist.example.com:4004")

    view = mint(conn)

    assert has_element?(view, "#agent-connect-panel")
    refute has_element?(view, "#connect-url-warning")
  end

  test "loopback raises no warning, plain http being allowed there", %{conn: conn} do
    put_public_url(scheme: "http", host: "localhost", port: 4000)
    compose_mcp_url()

    view = mint(conn)

    assert has_element?(view, "#agent-connect-panel")
    refute has_element?(view, "#connect-url-warning")
    refute has_element?(view, "#connect-mcp-url-warning")
  end

  test "a composed off-origin MCP address warns, naming it and MCP_PUBLIC_URL", %{conn: conn} do
    put_public_url(scheme: "https", host: "doitlist.example.com", port: 443)
    compose_mcp_url()

    view = mint(conn)

    assert has_element?(view, "#connect-mcp-url-warning")
    # The https public URL is fine on its own — only the MCP notice fires.
    refute has_element?(view, "#connect-url-warning")

    warning = view |> element("#connect-mcp-url-warning") |> render()
    assert warning =~ "https://doitlist.example.com:4004"
    assert warning =~ "not the address serving this page"
    assert warning =~ "MCP_PUBLIC_URL"
  end

  test "an MCP_PUBLIC_URL override raises no MCP notice", %{conn: conn} do
    put_public_url(scheme: "https", host: "doitlist.example.com", port: 443)
    Application.put_env(:doit, :mcp_public_url, "https://doitlist.example.com/mcp")

    view = mint(conn)

    assert has_element?(view, "#agent-connect-panel")
    refute has_element?(view, "#connect-mcp-url-warning")
  end

  test "an MCP address on the page's own origin raises no MCP notice", %{conn: conn} do
    put_public_url(scheme: "https", host: "doitlist.example.com", port: 4004)
    compose_mcp_url()

    view = mint(conn)

    assert has_element?(view, "#agent-connect-panel")
    refute has_element?(view, "#connect-mcp-url-warning")
  end
end
