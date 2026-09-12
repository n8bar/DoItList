defmodule DoIt.Api.IdempotencyKey do
  @moduledoc """
  A stored `POST /api/v1/operations` response, keyed by `(user_id,
  idempotency_key)` (m03.03 worklist 2.2).

  Records what the FIRST attempt of a request produced — its HTTP status and
  JSON body — so a retry carrying the same client-supplied `Idempotency-Key`
  replays that response verbatim instead of re-applying the batch.
  `payload_hash` binds the key to the exact payload it was first used with
  (m03.04 fix 20): a same-key request whose payload hashes differently is
  rejected, not replayed (nil only on rows predating the column). `inserted_at`
  anchors the retention window (see `DoIt.Api.Idempotency`); rows are write-once,
  so there is no `updated_at`.

  `user_id` is set programmatically when building the struct (never cast).
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "api_idempotency_keys" do
    field :idempotency_key, :string
    field :payload_hash, :binary
    field :response_status, :integer
    field :response_body, :map

    belongs_to :user, DoIt.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Changeset for a stored response. `user_id` is set programmatically on the
  struct — never cast — for security.
  """
  def changeset(record, attrs) do
    record
    |> cast(attrs, [:idempotency_key, :payload_hash, :response_status, :response_body])
    |> validate_required([:idempotency_key, :payload_hash, :response_status, :response_body])
    |> unique_constraint([:user_id, :idempotency_key])
  end
end
