defmodule DoItWeb.AccountConnectUrlTest do
  @moduledoc """
  m03.04 6.17: the connect panel warns when the URL its pastes are about to
  carry is one every client refuses — plain http off loopback — and stays quiet
  for https and for loopback. `async: false`: flips the endpoint's public URL,
  which is global.
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

    on_exit(fn ->
      Application.put_env(:doit, DoItWeb.Endpoint, prev_endpoint)
      DoItWeb.Endpoint.config_change([{DoItWeb.Endpoint, prev_endpoint}], [])
    end)

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    %{conn: conn}
  end

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

  test "a plain-http LAN URL warns, naming the URL and what to set", %{conn: conn} do
    put_public_url(scheme: "http", host: "192.168.68.31", port: 4000)

    view = mint(conn)

    assert has_element?(view, "#connect-url-warning")

    warning = view |> element("#connect-url-warning") |> render()
    assert warning =~ "http://192.168.68.31:4000"
    assert warning =~ "which agent clients refuse"
    assert warning =~ "plain http works only on localhost"
    assert warning =~ "PUBLIC_SCHEME, PUBLIC_HOST, PUBLIC_PORT"
  end

  test "an https public URL raises no warning", %{conn: conn} do
    put_public_url(scheme: "https", host: "doitlist.example.com", port: 443)
    Application.put_env(:doit, :mcp_public_url, "https://doitlist.example.com:4004")
    on_exit(fn -> Application.put_env(:doit, :mcp_public_url, nil) end)

    view = mint(conn)

    assert has_element?(view, "#agent-connect-panel")
    refute has_element?(view, "#connect-url-warning")
  end

  test "loopback raises no warning, plain http being allowed there", %{conn: conn} do
    put_public_url(scheme: "http", host: "localhost", port: 4000)

    view = mint(conn)

    assert has_element?(view, "#agent-connect-panel")
    refute has_element?(view, "#connect-url-warning")
  end
end
