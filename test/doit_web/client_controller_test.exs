defmodule DoItWeb.ClientControllerTest do
  @moduledoc """
  The React client's bootstrap document at `/app` (m04.01 worklist 2).

  Covers what the document must carry (identity, CSRF, theme, loading and
  recovery states), what it must NOT carry (a bearer token, product-shaped
  server-rendered controls), and that every path under `/app` is the same
  document while `/app/api` stays JSON.
  """
  use DoItWeb.ConnCase, async: true

  alias DoIt.Accounts

  defp user do
    {:ok, u} =
      Accounts.register_user(%{
        "email" => "boot-#{System.unique_integer([:positive])}@example.com",
        "username" => "boot-#{System.unique_integer([:positive])}",
        "name" => "Boot Tester",
        "password" => "password123"
      })

    u
  end

  defp sign_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, user.id)
  end

  defp bootstrap_payload(html) do
    [_, json] =
      Regex.run(~r|<script type="application/json" id="bootstrap">(.*?)</script>|s, html)

    Jason.decode!(json)
  end

  describe "the bootstrap document" do
    test "carries the signed-in user and a CSRF token, and no bearer token", %{conn: conn} do
      user = user()
      html = conn |> sign_in(user) |> get(~p"/app") |> html_response(200)

      payload = bootstrap_payload(html)

      assert payload["user"]["id"] == user.id
      assert payload["user"]["email"] == user.email
      assert payload["user"]["username"] == user.username
      assert is_binary(payload["csrf_token"]) and payload["csrf_token"] != ""
      assert payload["path"] == "/app"

      # The session cookie is the credential (spec §12) — nothing token-shaped
      # is ever written into the document.
      refute payload["token"]
      refute html =~ "Bearer"
      refute html =~ "authorization"
      refute String.contains?(String.downcase(html), "api_token")
    end

    test "publishes the CSRF token as a meta tag for the client's writes", %{conn: conn} do
      html = conn |> sign_in(user()) |> get(~p"/app") |> html_response(200)

      assert html =~ ~s(name="csrf-token")
    end

    test "is a 200 with a null user when signed out — no redirect", %{conn: conn} do
      html = conn |> get(~p"/app") |> html_response(200)

      assert bootstrap_payload(html)["user"] == nil
    end

    test "paints a loading state, a noscript message, and the client bundle", %{conn: conn} do
      html = conn |> sign_in(user()) |> get(~p"/app") |> html_response(200)

      assert html =~ ~s(id="app")
      assert html =~ ~s(role="status")
      assert html =~ "Loading Do It List"
      assert html =~ "<noscript>"
      assert html =~ "needs JavaScript"
      assert html =~ "/assets/js/client.js"
    end

    test "guards the bundle with an asset-failure handler and a watchdog", %{conn: conn} do
      html = conn |> sign_in(user()) |> get(~p"/app") |> html_response(200)

      assert html =~ "__doitBootFail('asset')"
      assert html =~ "__doit_client_ready"
      assert html =~ ~s(id="boot-reload")
      assert html =~ "Reload"
    end

    test "server-renders no product-shaped controls", %{conn: conn} do
      html = conn |> sign_in(user()) |> get(~p"/app") |> html_response(200)

      refute html =~ "phx-"
      refute html =~ "Initiative"
      refute html =~ ~s(<form)
    end

    test "serves the same document for any path under /app", %{conn: conn} do
      conn = conn |> sign_in(user())
      html = conn |> get("/app/initiatives/42") |> html_response(200)

      assert bootstrap_payload(html)["path"] == "/app/initiatives/42"
      assert html =~ "Loading Do It List"
    end

    test "answers an unknown /app/api path with JSON, not the document", %{conn: conn} do
      conn = conn |> sign_in(user()) |> get("/app/api/nope")

      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end

  describe "first-paint theme" do
    test "runs the shared theme script before the client loads", %{conn: conn} do
      html = conn |> sign_in(user()) |> get(~p"/app") |> html_response(200)

      assert html =~ "phx:theme"
      assert html =~ "data-theme-system"
      assert html =~ "prefers-color-scheme: dark"
    end

    test "honours the signed-in user's saved theme on the html element", %{conn: conn} do
      user = user()
      {:ok, user} = Accounts.update_theme(user, "dark")

      html = conn |> sign_in(user) |> get(~p"/app") |> html_response(200)

      assert html =~ ~s(data-theme="dark")
    end

    test "is the same source as the LiveView root layout's", %{conn: conn} do
      client = conn |> sign_in(user()) |> get(~p"/app") |> html_response(200)
      live = conn |> get(~p"/") |> html_response(200)

      # Not a lookalike: both documents render DoItWeb.Layouts.theme_script/1,
      # so the script text is character-identical in both.
      script =
        ~r|<script>.*?phx:theme.*?</script>|s
        |> Regex.run(client)
        |> hd()

      assert String.contains?(live, script)

      root = File.read!("lib/doit_web/components/layouts/root.html.heex")
      template = File.read!("lib/doit_web/controllers/client_html/index.html.heex")
      assert root =~ "theme_script"
      assert template =~ "theme_script"
      refute root =~ "localStorage.getItem"
    end
  end
end
