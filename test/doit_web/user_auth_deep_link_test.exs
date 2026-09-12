defmodule DoItWeb.UserAuthDeepLinkTest do
  @moduledoc """
  Deep links survive login (m03.04 item 6.1): an Initiative URL opened while
  logged out parks its path in the session, and `log_in_user/2` returns the user
  there instead of dumping them on the Initiative list. Only local paths are
  honoured — the parked value is never an open-redirect target.
  """
  use DoItWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DoIt.{Accounts, Initiatives}
  alias DoItWeb.UserAuth

  @password "password123"

  defp user(name) do
    n = System.unique_integer([:positive])

    {:ok, u} =
      Accounts.register_user(%{
        "email" => "#{name}-#{n}@example.com",
        "username" => "#{name}-#{n}",
        "name" => String.capitalize(name),
        "password" => @password
      })

    u
  end

  defp initiative(owner) do
    {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Deep link"})
    ini
  end

  defp log_in(conn, user) do
    post(conn, ~p"/users/log_in", %{
      "user" => %{"login" => user.username, "password" => @password}
    })
  end

  # A root mount's socket, as `on_mount/4` sees it before any assigns exist.
  defp mount_socket(connect_info) do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, flash: %{}},
      private: %{connect_info: connect_info, live_temp: %{}},
      view: DoItWeb.InitiativeWorkspaceLive
    }
  end

  describe "requested path through login" do
    test "a logged-out Initiative URL lands back on that Initiative", %{conn: conn} do
      owner = user("deep")
      ini = initiative(owner)
      path = "/initiatives/#{ini.id}"

      conn = get(conn, path)
      assert redirected_to(conn) == ~p"/users/log_in"
      assert get_session(conn, :user_return_to) == path

      conn = log_in(conn, owner)
      assert redirected_to(conn) == path
      refute get_session(conn, :user_return_to)

      conn = get(conn, path)
      assert html_response(conn, 200)
    end

    test "the deep-linked Initiative mounts live after login", %{conn: conn} do
      owner = user("deep")
      ini = initiative(owner)
      path = "/initiatives/#{ini.id}"

      conn = conn |> get(path) |> log_in(owner)
      assert redirected_to(conn) == path

      assert {:ok, _view, _html} = live(conn, path)
    end

    test "a query string round-trips", %{conn: conn} do
      owner = user("deep")
      ini = initiative(owner)
      path = "/initiatives/#{ini.id}?foo=bar"

      conn = get(conn, path)
      assert get_session(conn, :user_return_to) == path

      conn = log_in(conn, owner)
      assert redirected_to(conn) == path
    end

    test "a plain login lands on the Initiative list", %{conn: conn} do
      owner = user("plain")

      conn = log_in(conn, owner)
      assert redirected_to(conn) == ~p"/initiatives"
    end

    test "a non-GET request parks nothing", %{conn: conn} do
      conn = delete(conn, ~p"/users/log_out")

      assert redirected_to(conn) == ~p"/users/log_in"
      refute get_session(conn, :user_return_to)
    end
  end

  describe "non-local parked paths" do
    test "are ignored and cleared at login" do
      owner = user("hostile")

      for hostile <- [
            "https://evil.example/x",
            "//evil.example/x",
            "/\\evil.example/x",
            "javascript:alert(1)"
          ] do
        conn =
          build_conn()
          |> init_test_session(%{user_return_to: hostile})
          |> log_in(owner)

        assert redirected_to(conn) == ~p"/initiatives", "expected #{hostile} to be rejected"
        refute get_session(conn, :user_return_to)
      end
    end

    test "local_return_path/1 keeps local paths and drops the rest" do
      assert UserAuth.local_return_path("/initiatives/7") == "/initiatives/7"
      assert UserAuth.local_return_path("/initiatives/7?foo=bar") == "/initiatives/7?foo=bar"

      refute UserAuth.local_return_path("https://evil.example/x")
      refute UserAuth.local_return_path("//evil.example/x")
      refute UserAuth.local_return_path("/\\evil.example/x")
      refute UserAuth.local_return_path("javascript:alert(1)")
      refute UserAuth.local_return_path("initiatives/7")
      refute UserAuth.local_return_path(" /initiatives/7")
      refute UserAuth.local_return_path(nil)
    end
  end

  describe "halted LiveView mount" do
    test "forwards the requested path to the login page" do
      socket = mount_socket(%{uri: %URI{path: "/initiatives/7", query: "foo=bar"}})

      assert {:halt, socket} = UserAuth.on_mount(:require_authenticated, %{}, %{}, socket)
      assert {:redirect, %{to: to}} = socket.redirected

      assert %URI{path: "/users/log_in", query: query} = URI.parse(to)
      assert URI.decode_query(query) == %{"return_to" => "/initiatives/7?foo=bar"}
    end

    test "forwards nothing when the path is missing or non-local" do
      for connect_info <- [%{}, %{uri: %URI{path: "//evil.example/x"}}] do
        socket = mount_socket(connect_info)

        assert {:halt, socket} = UserAuth.on_mount(:require_authenticated, %{}, %{}, socket)
        assert {:redirect, %{to: "/users/log_in"}} = socket.redirected
      end
    end

    test "the forwarded path is parked by the login page and honoured", %{conn: conn} do
      owner = user("forwarded")
      ini = initiative(owner)
      path = "/initiatives/#{ini.id}"

      conn = get(conn, ~p"/users/log_in?#{[return_to: path]}")
      assert html_response(conn, 200)
      assert get_session(conn, :user_return_to) == path

      conn = log_in(conn, owner)
      assert redirected_to(conn) == path
    end

    test "a non-local forwarded path is dropped by the login page", %{conn: conn} do
      owner = user("forwarded")

      conn = get(conn, ~p"/users/log_in?#{[return_to: "https://evil.example/x"]}")
      assert html_response(conn, 200)
      refute get_session(conn, :user_return_to)

      conn = log_in(conn, owner)
      assert redirected_to(conn) == ~p"/initiatives"
    end
  end
end
