defmodule DoIt.Repo.Migrations.AddTrashedAtToInitiatives do
  use Ecto.Migration

  def change do
    # Trash (m02.06 item 10): deleting an Initiative routes it here instead of a
    # hard delete; a trashed Initiative leaves every member's dashboard until
    # restored or purged (manually or by the retention sweep).
    alter table(:initiatives) do
      add :trashed_at, :utc_datetime
    end

    create index(:initiatives, [:owner_id], where: "trashed_at IS NOT NULL", name: :initiatives_trashed_by_owner_index)
  end
end
