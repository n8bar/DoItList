defmodule DoIt.Repo.Migrations.IndexApiIdempotencyKeysOnPayloadHash do
  use Ecto.Migration

  # m03.04 2.7.6: a committed batch is never re-applied under a new key. Every
  # keyed miss now looks up "has THIS user already committed THIS payload under
  # some other key?" (`DoIt.Api.Idempotency.prior_commit/3`) — this index makes
  # that lookup a probe instead of a per-user row scan on the API hot path.
  def change do
    create index(:api_idempotency_keys, [:user_id, :payload_hash])
  end
end
