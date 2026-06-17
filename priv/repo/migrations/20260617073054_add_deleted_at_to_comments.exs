defmodule DoIt.Repo.Migrations.AddDeletedAtToComments do
  use Ecto.Migration

  def change do
    # Soft-delete for comments (m02.06 item 14.5): undoing a comment clears it
    # by setting this; redo restores it. Same mechanism as tasks.deleted_at, so
    # the comment's id / body / author / timestamp survive the round-trip.
    alter table(:comments) do
      add :deleted_at, :utc_datetime
    end
  end
end
