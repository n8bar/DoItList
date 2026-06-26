defmodule DoIt.Accounts.ApiToken do
  @moduledoc """
  A per-user API access token (m03.01 worklist 1.1).

  Only a **hash** of the token is persisted (`token_hash`); the plaintext is
  generated and returned exactly once, at mint, and is never stored or
  recoverable. A presented Bearer token is hashed the same way and looked up
  against `token_hash` (see `DoIt.Accounts.ApiTokens`).

  Tokens identify a user and act under that user's existing Initiative role —
  they carry no extra scope of their own.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "api_tokens" do
    field :token_hash, :string, redact: true
    field :label, :string
    field :last_used_at, :utc_datetime

    belongs_to :user, DoIt.Accounts.User

    # No `updated_at`: rows are immutable except for `last_used_at`, which is
    # bumped in place. `inserted_at` is the mint time surfaced in the UI.
    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Changeset for the user-supplied label. `user_id` and `token_hash` are set
  programmatically at mint (never cast) for security.
  """
  def changeset(token, attrs) do
    token
    |> cast(attrs, [:label])
    |> update_change(:label, &normalize_label/1)
    |> validate_length(:label, max: 100)
  end

  defp normalize_label(nil), do: nil

  defp normalize_label(label) when is_binary(label) do
    case String.trim(label) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
