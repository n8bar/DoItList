defmodule DoIt.Repo.Migrations.AddUndoneAtToActivityEvents do
  use Ecto.Migration

  def change do
    # Undo state (m02.06 item 3): an undone event carries when it was reversed.
    # The per-(user, Initiative) stack is derived from this + the row ids — no
    # separate pointer table.
    alter table(:activity_events) do
      add :undone_at, :utc_datetime
    end

    create index(:activity_events, [:user_id, :initiative_id, :kind])
  end
end
