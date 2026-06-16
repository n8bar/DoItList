defmodule DoIt.Repo.Migrations.AddSoftDeleteAndInversePayload do
  use Ecto.Migration

  def change do
    # Soft-delete for tasks (m02.06): undo / Trash restore by clearing this.
    alter table(:tasks) do
      add :deleted_at, :utc_datetime
    end

    # Partial index — the common read path filters to live rows.
    create index(:tasks, [:initiative_id],
             where: "deleted_at IS NULL",
             name: :tasks_live_by_initiative_index
           )

    # Per-event reversal data for the undo engine (m02.06 item 1). The diff
    # events already carry from/to in `data`; this holds the extras (e.g. a
    # move's prior sort position) some inverses need.
    alter table(:activity_events) do
      add :inverse_payload, :map
    end
  end
end
