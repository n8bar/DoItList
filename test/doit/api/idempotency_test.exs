defmodule DoIt.Api.IdempotencyTest do
  @moduledoc """
  Store-and-replay for client-supplied idempotency keys (m03.03 worklist 2.2).

  Pure domain unit tests: a miss returns nil; a store then fetch round-trips the
  status + body; a row older than the retention window no longer matches; and a
  concurrent second store of the same key is swallowed, not crashed.
  """
  use DoIt.DataCase, async: true

  alias DoIt.Accounts
  alias DoIt.Api.{Idempotency, IdempotencyKey}
  alias DoIt.Repo

  defp user do
    n = System.unique_integer([:positive])

    {:ok, u} =
      Accounts.register_user(%{
        "email" => "idem-#{n}@example.com",
        "username" => "idem-#{n}",
        "name" => "Idem",
        "password" => "password123"
      })

    u
  end

  test "fetch miss returns nil" do
    assert Idempotency.fetch(user(), "never-stored") == nil
  end

  test "store then fetch round-trips the status and body" do
    u = user()
    body = %{"results" => [%{"index" => 0, "status" => "ok"}]}

    assert :ok = Idempotency.store(u, "k1", 200, body)
    assert {200, ^body} = Idempotency.fetch(u, "k1")
  end

  test "the key is scoped per user — another user's same key doesn't match" do
    u1 = user()
    u2 = user()

    assert :ok = Idempotency.store(u1, "shared", 200, %{"results" => []})

    assert {200, _} = Idempotency.fetch(u1, "shared")
    assert Idempotency.fetch(u2, "shared") == nil
  end

  test "a row older than the retention window is not returned" do
    u = user()

    # Backdate inserted_at past the 24h window by inserting the struct directly
    # (timestamps only autogenerate when the field is nil).
    old = DateTime.utc_now() |> DateTime.add(-25, :hour) |> DateTime.truncate(:second)

    Repo.insert!(%IdempotencyKey{
      user_id: u.id,
      idempotency_key: "stale",
      response_status: 200,
      response_body: %{"results" => []},
      inserted_at: old
    })

    assert Idempotency.fetch(u, "stale") == nil
  end

  test "storing the same key twice does not crash (concurrent-store race)" do
    u = user()

    assert :ok = Idempotency.store(u, "dup", 200, %{"results" => [%{"a" => 1}]})
    # A second store of the same key (a losing race) is swallowed.
    assert :ok = Idempotency.store(u, "dup", 422, %{"error" => %{"code" => "x"}})

    # The FIRST stored response wins — the conflict was a no-op, not an overwrite.
    assert {200, %{"results" => [%{"a" => 1}]}} = Idempotency.fetch(u, "dup")
  end
end
