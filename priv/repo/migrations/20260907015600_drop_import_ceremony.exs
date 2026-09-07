defmodule DoIt.Repo.Migrations.DropImportCeremony do
  use Ecto.Migration

  # m03.04 3.1: the first-pass import ceremony is gone — no approvals to park,
  # no declarations to check, no account-level off-switch. Drops its two
  # tables, its users column, and the notification rows that pointed at cards
  # which no longer render.
  def up do
    execute("DELETE FROM notifications WHERE kind = 'import_approval_requested'")

    drop table(:import_approvals)
    drop table(:import_declarations)

    alter table(:users) do
      remove :skip_import_approvals
    end
  end

  # Recreates the schema exactly as the ceremony's own migrations left it
  # (20260821025135, 20260825025148, 20260822053648, 20260821213900). The
  # deleted notification rows are not restorable.
  def down do
    alter table(:users) do
      add :skip_import_approvals, :boolean, default: false, null: false
    end

    create table(:import_approvals) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :payload_hash, :string, null: false
      add :task_count, :integer, null: false
      add :initiative_name, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :sample, :map, default: nil
      add :decision_reason, :string, size: 500, default: nil

      timestamps(type: :utc_datetime)
    end

    create index(:import_approvals, [:user_id, :payload_hash])
    create index(:import_approvals, [:user_id, :status])

    create table(:import_declarations) do
      add :initiative_id, references(:initiatives, on_delete: :delete_all), null: false
      add :source_total, :integer, null: false
      add :source_completed, :integer, null: false
      add :excluded_count, :integer, null: false, default: 0
      add :exclusions, :text
      add :ordering, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:import_declarations, [:initiative_id])
  end
end
