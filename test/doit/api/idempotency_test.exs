defmodule DoIt.Api.IdempotencyTest do
  @moduledoc """
  Store-and-replay for client-supplied idempotency keys (m03.03 worklist 2.2),
  with the key bound to its payload hash (m03.04 fix 20).

  Pure domain unit tests: a miss returns nil; a store then fetch with the same
  hash round-trips the status + body; a fetch with a different hash is a
  payload conflict; a legacy row with no stored hash still replays; a row older
  than the retention window no longer matches; and a concurrent second store of
  the same key is swallowed, not crashed.
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

  defp hash(ops), do: Idempotency.payload_hash(ops)

  test "payload_hash is equal for equal payloads and differs when an op changes" do
    ops = [%{"op" => "add", "type" => "task", "data" => %{"title" => "A"}}]
    same = [%{"op" => "add", "type" => "task", "data" => %{"title" => "A"}}]
    changed = [%{"op" => "add", "type" => "task", "data" => %{"title" => "B"}}]

    assert hash(ops) == hash(same)
    refute hash(ops) == hash(changed)
  end

  test "fetch miss returns nil" do
    assert Idempotency.fetch(user(), "never-stored", hash([])) == nil
  end

  test "store then fetch with the same payload hash replays the status and body" do
    u = user()
    h = hash([%{"op" => "add"}])
    body = %{"results" => [%{"index" => 0, "status" => "ok"}]}

    assert :ok = Idempotency.store(u, "k1", h, 200, body)
    assert {:replay, {200, ^body}} = Idempotency.fetch(u, "k1", h)
  end

  test "fetch with a differing payload hash is a payload conflict, not a replay" do
    u = user()

    assert :ok = Idempotency.store(u, "k2", hash([%{"op" => "add"}]), 200, %{"results" => []})
    assert Idempotency.fetch(u, "k2", hash([%{"op" => "delete"}])) == :payload_conflict
  end

  test "a legacy row with no stored hash replays for any payload" do
    u = user()

    # Pre-migration rows carry no payload_hash; they stay replayable until they
    # age out of the retention window.
    Repo.insert!(%IdempotencyKey{
      user_id: u.id,
      idempotency_key: "legacy",
      response_status: 200,
      response_body: %{"results" => []}
    })

    assert {:replay, {200, _}} = Idempotency.fetch(u, "legacy", hash([%{"op" => "add"}]))
  end

  test "the key is scoped per user — another user's same key doesn't match" do
    u1 = user()
    u2 = user()
    h = hash([%{"op" => "add"}])

    assert :ok = Idempotency.store(u1, "shared", h, 200, %{"results" => []})

    assert {:replay, {200, _}} = Idempotency.fetch(u1, "shared", h)
    assert Idempotency.fetch(u2, "shared", h) == nil
  end

  test "a row older than the retention window is not returned" do
    u = user()
    h = hash([%{"op" => "add"}])

    # Backdate inserted_at past the 24h window by inserting the struct directly
    # (timestamps only autogenerate when the field is nil).
    old = DateTime.utc_now() |> DateTime.add(-25, :hour) |> DateTime.truncate(:second)

    Repo.insert!(%IdempotencyKey{
      user_id: u.id,
      idempotency_key: "stale",
      payload_hash: h,
      response_status: 200,
      response_body: %{"results" => []},
      inserted_at: old
    })

    assert Idempotency.fetch(u, "stale", h) == nil
  end

  test "storing the same key twice does not crash (concurrent-store race)" do
    u = user()
    h = hash([%{"op" => "add"}])

    assert :ok = Idempotency.store(u, "dup", h, 200, %{"results" => [%{"a" => 1}]})
    # A second store of the same key (a losing race) is swallowed.
    assert :ok = Idempotency.store(u, "dup", h, 422, %{"error" => %{"code" => "x"}})

    # The FIRST stored response wins — the conflict was a no-op, not an overwrite.
    assert {:replay, {200, %{"results" => [%{"a" => 1}]}}} = Idempotency.fetch(u, "dup", h)
  end
end
