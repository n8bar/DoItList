defmodule DoIt.Api.Idempotency do
  @moduledoc """
  Store-and-replay for client-supplied idempotency keys on
  `POST /api/v1/operations` (m03.03 worklist 2.2).

  A client that times out mid-request has no way to tell whether its batch
  committed; retrying risks double-applying it. Mirroring Stripe, the client
  sends an `Idempotency-Key` header (only the client knows "this is the same
  logical request as my last, failed one"). The controller looks the key up
  before executing: on a hit it replays the stored response; on a miss it runs
  the batch and stores the exact response it sends.

  The key **binds to its exact payload** (m03.04 fix 20): a hash of the decoded
  operations is stored beside the key, and a same-key request whose payload
  hashes differently is a `:payload_conflict` — the controller rejects it
  instead of replaying, so a reused key can never silently mask a changed
  batch. A revised batch takes a new key.

  Pure business logic over `DoIt.Api.IdempotencyKey` — no controller/Plug deps —
  so it is unit-testable in isolation.

  ## Retention window

  A stored response is only replayable while it is fresh. `@retention_hours`
  (24h) is the window; it is **retunable** — long enough to cover any realistic
  client retry, short enough that the table doesn't grow without bound. Lookups
  are windowed (`fetch/2` matches only rows inside the window), so an expired row
  simply stops matching — correctness never depends on a sweep having run.
  """

  import Ecto.Query, only: [from: 2]

  alias DoIt.Accounts.User
  alias DoIt.Api.IdempotencyKey
  alias DoIt.Repo

  # How long a stored response stays replayable. Retunable.
  @retention_hours 24

  @doc """
  The hash that binds an idempotency key to its payload (m03.04 fix 20).

  SHA-256 over the decoded operations' Erlang external term form: equal decoded
  payloads hash equal, any changed op differs. Same-VM comparison only, so
  `term_to_binary`'s map encoding is stable enough here.
  """
  @spec payload_hash(term()) :: binary()
  def payload_hash(operations),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(operations))

  @doc """
  Look up the stored response for `(user, key)`, checking `payload_hash`.

  Returns `{:replay, {status, body}}` when a row exists, its `inserted_at` is
  within the retention window, AND its stored hash matches (a nil stored hash —
  a row predating the hash column — matches anything); `:payload_conflict` when
  the row matches but its hash differs (a reused key with a changed payload);
  otherwise `nil` (a miss, or an expired row that no longer matches). `body`
  comes back with string keys (jsonb round-trip), which is what the controller
  re-encodes to JSON.
  """
  @spec fetch(User.t(), String.t(), binary()) ::
          {:replay, {integer(), map()}} | :payload_conflict | nil
  def fetch(%User{} = user, key, payload_hash) when is_binary(key) do
    cutoff = DateTime.add(DateTime.utc_now(), -@retention_hours, :hour)

    query =
      from r in IdempotencyKey,
        where:
          r.user_id == ^user.id and r.idempotency_key == ^key and
            r.inserted_at >= ^cutoff,
        select: {r.response_status, r.response_body, r.payload_hash}

    case Repo.one(query) do
      nil ->
        nil

      {status, body, stored_hash} when is_nil(stored_hash) or stored_hash == payload_hash ->
        {:replay, {status, body}}

      _mismatch ->
        :payload_conflict
    end
  end

  @doc """
  Record the response `(status, body)` for `(user, key)`, bound to
  `payload_hash`.

  Returns `:ok`. A concurrent request may have stored the same key first; the
  unique index on `(user_id, idempotency_key)` then makes this a no-op via
  `on_conflict: :nothing` — the key is recorded either way, so a losing race is
  still a success.
  """
  @spec store(User.t(), String.t(), binary(), integer(), map()) :: :ok
  def store(%User{} = user, key, payload_hash, status, body) when is_binary(key) do
    %IdempotencyKey{user_id: user.id}
    |> IdempotencyKey.changeset(%{
      "idempotency_key" => key,
      "payload_hash" => payload_hash,
      "response_status" => status,
      "response_body" => body
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :idempotency_key])

    :ok
  end
end
