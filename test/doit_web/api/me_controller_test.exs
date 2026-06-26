defmodule DoItWeb.Api.MeControllerTest do
  @moduledoc """
  Bearer auth on the anchor endpoint `GET /api/v1/me` (m03.01 worklist 1.3):
  a valid token returns 200 with the acting user; missing / malformed / invalid
  / revoked tokens are rejected with a 401 in the single-error JSON shape.
  """
  use DoItWeb.ConnCase, async: true

  alias DoIt.Accounts

  defp user(name \\ "api") do
    {:ok, u} =
      Accounts.register_user(%{
        "email" => "#{name}-#{System.unique_integer([:positive])}@example.com",
        "username" => "#{name}-#{System.unique_integer([:positive])}",
        "name" => String.capitalize(name),
        "password" => "password123"
      })

    u
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  test "valid token returns 200 with the acting user", %{conn: conn} do
    user = user()
    {:ok, {plaintext, _}} = Accounts.mint_api_token(user, "test")

    conn = conn |> bearer(plaintext) |> get(~p"/api/v1/me")

    assert %{"data" => data} = json_response(conn, 200)
    assert data["id"] == user.id
    assert data["email"] == user.email
    assert data["username"] == user.username
  end

  test "missing Authorization header is 401", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/me")
    assert %{"error" => error} = json_response(conn, 401)
    assert error["status"] == 401
    assert error["code"] == "unauthorized"
    assert is_binary(error["message"])
  end

  test "a non-Bearer / malformed header is 401", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Basic abc123")
      |> get(~p"/api/v1/me")

    assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
  end

  test "an empty bearer value is 401", %{conn: conn} do
    conn = conn |> bearer("   ") |> get(~p"/api/v1/me")
    assert json_response(conn, 401)["error"]["code"] == "unauthorized"
  end

  test "a garbage token is 401", %{conn: conn} do
    conn = conn |> bearer("doit_pat_garbage") |> get(~p"/api/v1/me")
    assert json_response(conn, 401)["error"]["code"] == "unauthorized"
  end

  test "a revoked token is 401", %{conn: conn} do
    user = user()
    {:ok, {plaintext, token}} = Accounts.mint_api_token(user, "temp")
    {:ok, _} = Accounts.revoke_api_token(user, token.id)

    conn = conn |> bearer(plaintext) |> get(~p"/api/v1/me")
    assert json_response(conn, 401)["error"]["code"] == "unauthorized"
  end
end
