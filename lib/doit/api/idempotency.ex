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
  Look up the stored response for `(user, key)`.

  Returns `{status, body}` when a row exists AND its `inserted_at` is within the
  retention window; otherwise `nil` (a miss, or an expired row that no longer
  matches). `body` comes back with string keys (jsonb round-trip), which is what
  the controller re-encodes to JSON.
  """
  @spec fetch(User.t(), String.t()) :: {integer(), map()} | nil
  def fetch(%User{} = user, key) when is_binary(key) do
    cutoff = DateTime.add(DateTime.utc_now(), -@retention_hours, :hour)

    query =
      from r in IdempotencyKey,
        where:
          r.user_id == ^user.id and r.idempotency_key == ^key and
            r.inserted_at >= ^cutoff,
        select: {r.response_status, r.response_body}

    Repo.one(query)
  end

  @doc """
  Record the response `(status, body)` for `(user, key)`.

  Returns `:ok`. A concurrent request may have stored the same key first; the
  unique index on `(user_id, idempotency_key)` then makes this a no-op via
  `on_conflict: :nothing` — the key is recorded either way, so a losing race is
  still a success.
  """
  @spec store(User.t(), String.t(), integer(), map()) :: :ok
  def store(%User{} = user, key, status, body) when is_binary(key) do
    %IdempotencyKey{user_id: user.id}
    |> IdempotencyKey.changeset(%{
      "idempotency_key" => key,
      "response_status" => status,
      "response_body" => body
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :idempotency_key])

    :ok
  end
end
