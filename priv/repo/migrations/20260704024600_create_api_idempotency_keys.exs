defmodule DoIt.Repo.Migrations.CreateApiIdempotencyKeys do
  use Ecto.Migration

  def change do
    # Client-supplied idempotency keys for `POST /api/v1/operations` (m03.03
    # worklist 2.2), mirroring Stripe's `Idempotency-Key` convention. A retry
    # after a client-side timeout carries the same key; the original response is
    # replayed instead of re-applying the batch.
    #
    # A row records the response the FIRST attempt produced, keyed by
    # `(user_id, idempotency_key)`. Rows are write-once (never updated), so
    # there is no `updated_at`; `inserted_at` anchors the retention window
    # (`DoIt.Api.Idempotency` only replays a row still inside it).
    create table(:api_idempotency_keys) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :idempotency_key, :string, null: false
      add :response_status, :integer, null: false
      add :response_body, :map, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    # The key is scoped to the user, so the same string from two users is two
    # distinct records. This unique index is both the dedupe guarantee and the
    # lookup path; it also lets a concurrent second store settle via
    # `on_conflict: :nothing`.
    create unique_index(:api_idempotency_keys, [:user_id, :idempotency_key])
  end
end
