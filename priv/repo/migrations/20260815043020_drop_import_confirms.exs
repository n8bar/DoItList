defmodule DoIt.Repo.Migrations.DropImportConfirms do
  use Ecto.Migration

  # m03.04 item 36: import consent rides the standing agent_access grant, so
  # the server-recorded confirm machinery (item 30) retires — the readback
  # now lands as a provenance comment on the target Initiative's root task.
  # Revive the table (and the machinery) from git; `down/0` restores the
  # exact schema 20260808004048_create_import_confirms built.
  def up do
    drop table(:import_confirms)
  end

  def down do
    create table(:import_confirms) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :initiative_id, references(:initiatives, on_delete: :delete_all)
      add :payload_hash, :string, null: false
      add :readback, :text, null: false
      add :status, :string, null: false, default: "pending"
      add :corrections, :text

      timestamps(type: :utc_datetime)
    end

    create index(:import_confirms, [:user_id, :payload_hash])
    create index(:import_confirms, [:initiative_id, :status])
    create index(:import_confirms, [:user_id, :status])
  end
end
