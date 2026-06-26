defmodule DoIt.Repo.Migrations.CreateApiTokens do
  use Ecto.Migration

  def change do
    # Per-user API access tokens (m03.01 worklist 1.1). Bearer tokens that act
    # as the user under their existing role; they carry no extra scope.
    #
    # We store ONLY a hash of the token (`token_hash`), never the plaintext —
    # the plaintext is shown once at mint and is unrecoverable thereafter. A
    # presented Bearer token is hashed the same way and matched against this
    # column, so the unique index doubles as the lookup path.
    create table(:api_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token_hash, :string, null: false
      add :label, :string
      add :last_used_at, :utc_datetime

      # Tokens are immutable except for `last_used_at`, which we bump in place
      # via update_all — no application-level `updated_at` to maintain.
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:api_tokens, [:token_hash])
    create index(:api_tokens, [:user_id])
  end
end
