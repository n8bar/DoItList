defmodule DoItWeb.Api.RateLimitTest do
  @moduledoc """
  Per-token rate limiting in the live `/api/v1` pipeline (m03.01 worklist 1.5).
  config/test.exs sets the cap to 5/window, so the 6th request on one token
  trips a 429 with a Retry-After hint. Each test mints a fresh token (unique id
  → its own counter), so the cap is deterministic.
  """
  use DoItWeb.ConnCase, async: true

  alias DoIt.Accounts

  @cap 5

  defp user do
    {:ok, u} =
      Accounts.register_user(%{
        "email" => "rl-#{System.unique_integer([:positive])}@example.com",
        "username" => "rl-#{System.unique_integer([:positive])}",
        "name" => "Rate Limited",
        "password" => "password123"
      })

    u
  end

  test "the cap-plus-one request on a token is 429 with a Retry-After hint", %{conn: _conn} do
    {:ok, {token, _}} = Accounts.mint_api_token(user(), "burst")

    # Up to the cap: all 200.
    for _ <- 1..@cap do
      resp =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> get(~p"/api/v1/me")

      assert resp.status == 200
    end

    # One over: 429 + single-error shape + Retry-After.
    over =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> get(~p"/api/v1/me")

    assert %{"error" => error} = json_response(over, 429)
    assert error["status"] == 429
    assert error["code"] == "rate_limited"
    assert [retry_after] = get_resp_header(over, "retry-after")
    assert String.to_integer(retry_after) > 0
  end

  test "a different token is unaffected by another's exhausted budget", %{conn: _conn} do
    {:ok, {hot, _}} = Accounts.mint_api_token(user(), "hot")
    {:ok, {cold, _}} = Accounts.mint_api_token(user(), "cold")

    for _ <- 1..(@cap + 1) do
      build_conn()
      |> put_req_header("authorization", "Bearer " <> hot)
      |> get(~p"/api/v1/me")
    end

    resp =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> cold)
      |> get(~p"/api/v1/me")

    assert resp.status == 200
  end
end
