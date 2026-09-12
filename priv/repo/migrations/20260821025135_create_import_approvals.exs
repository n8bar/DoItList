defmodule DoIt.Repo.Migrations.CreateImportApprovals do
  use Ecto.Migration

  # m03.04 2.8.8: the open-only bootstrap refusal's override is the operator's
  # own in-app click — a refused import parks here (account-homed; bootstrap
  # batches have no Initiative yet) and the operator approves or dismisses.
  # A slice of the item-30 import_confirms machinery (dropped at 2.8.4).
  def change do
    create table(:import_approvals) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :payload_hash, :string, null: false
      add :task_count, :integer, null: false
      add :initiative_name, :string, null: false
      add :status, :string, null: false, default: "pending"

      timestamps(type: :utc_datetime)
    end

    create index(:import_approvals, [:user_id, :payload_hash])
    create index(:import_approvals, [:user_id, :status])
  end
end
