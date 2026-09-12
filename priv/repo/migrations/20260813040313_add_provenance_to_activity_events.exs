defmodule DoIt.Repo.Migrations.AddProvenanceToActivityEvents do
  use Ecto.Migration

  # Execution provenance (m03.04 item 2.33): which actor performed the write,
  # beside the authorizing `user_id`. Nullable — existing rows stay null
  # (recorded before provenance) and render as today. Revoking a token deletes
  # its row (`Repo.delete`), so the FK nilifies and `api_token_label` keeps the
  # snapshotted identity readable after the token is gone.
  def change do
    alter table(:activity_events) do
      add :actor_kind, :string, size: 20
      add :api_token_id, references(:api_tokens, on_delete: :nilify_all)
      add :api_token_label, :string, size: 100
    end
  end
end
