defmodule DoIt.Repo.Migrations.AddPayloadHashToApiIdempotencyKeys do
  use Ecto.Migration

  # m03.04 fix 20: an idempotency key binds to its exact payload. The hash of
  # the decoded operations list is stored beside the key; a same-key request
  # whose hash differs is rejected instead of replayed. Nullable: rows from
  # before this migration have no hash and stay replayable until they age out
  # of the 24h retention window.
  def change do
    alter table(:api_idempotency_keys) do
      add :payload_hash, :binary
    end
  end
end
