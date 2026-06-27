defmodule DoItWeb.Api.RateLimitPlugTest do
  @moduledoc """
  Pins the contract between AuthPlug and RateLimitPlug (m03.01 worklist 1.5):
  AuthPlug must assign the token id under the *exact* key RateLimitPlug meters
  on, and RateLimitPlug must meter on a present key (not silently wave traffic
  through). A mismatch on either side is exactly what reads, on the live stack,
  as "rate limiting never enforces."
  """
  use DoItWeb.ConnCase, async: true

  alias DoIt.Accounts
  alias DoItWeb.Api.{AuthPlug, RateLimitPlug}

  @cap 5

  defp user do
    {:ok, u} =
      Accounts.register_user(%{
        "email" => "rlp-#{System.unique_integer([:positive])}@example.com",
        "username" => "rlp-#{System.unique_integer([:positive])}",
        "name" => "Rate Limit Plug",
        "password" => "password123"
      })

    u
  end

  test "AuthPlug assigns :api_token_id — the exact key RateLimitPlug meters on" do
    {:ok, {token, record}} = Accounts.mint_api_token(user(), "contract")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> AuthPlug.call([])

    refute conn.halted
    # If AuthPlug ever renamed this assign, RateLimitPlug would key on nil and
    # stop enforcing — so pin the literal key and the token id behind it.
    assert conn.assigns[:api_token_id] == record.id
  end

  test "RateLimitPlug meters on a present :api_token_id, halting past the cap" do
    id = System.unique_integer([:positive])

    call = fn ->
      build_conn()
      |> assign(:api_token_id, id)
      |> RateLimitPlug.call([])
    end

    for _ <- 1..@cap do
      conn = call.()
      refute conn.halted
    end

    over = call.()
    assert over.halted
    assert over.status == 429
    assert [retry_after] = get_resp_header(over, "retry-after")
    assert String.to_integer(retry_after) > 0
  end

  test "with no token id assigned, RateLimitPlug deliberately passes through" do
    # No auth ran (no key to meter on). The plug leaves the decision to the auth
    # layer rather than inventing a budget — a documented, deliberate path, not
    # an accidental fail-open: a wrongly-named assign would land here too, which
    # is precisely why the assign-contract test above exists to catch it.
    conn = RateLimitPlug.call(build_conn(), [])

    refute conn.halted
    assert conn.status == nil
  end
end
