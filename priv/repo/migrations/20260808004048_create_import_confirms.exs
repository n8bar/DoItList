defmodule DoIt.Repo.Migrations.CreateImportConfirms do
  use Ecto.Migration

  def change do
    # Server-recorded import confirms (m03.04 item 30): a gated MCP apply
    # parks its readback here; the operator decides in the app (Approve /
    # Correct / Hold) and the adapter reads the decision back by
    # `payload_hash` — the sha256 binding a confirm to the exact batch.
    # `initiative_id` nil = a bootstrap batch, homed on the account.
    create table(:import_confirms) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :initiative_id, references(:initiatives, on_delete: :delete_all)
      add :payload_hash, :string, null: false
      add :readback, :text, null: false
      add :status, :string, null: false, default: "pending"
      add :corrections, :text

      timestamps(type: :utc_datetime)
    end

    # The adapter's consult (latest row per user + hash) and the pages'
    # pending-card queries.
    create index(:import_confirms, [:user_id, :payload_hash])
    create index(:import_confirms, [:initiative_id, :status])
    create index(:import_confirms, [:user_id, :status])
  end
end
