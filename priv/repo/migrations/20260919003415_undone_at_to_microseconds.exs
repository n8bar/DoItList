defmodule DoIt.Repo.Migrations.UndoneAtToMicroseconds do
  use Ecto.Migration

  # m04.02 item 7.16: redo picks the most recently undone event by undone_at,
  # and a whole-second stamp ties every undo in the same second, so a tie broke
  # to the wrong event and the rest of the redo stack was blocked as "not on
  # top". Microseconds keep the undo sequence.
  def up do
    execute "ALTER TABLE activity_events ALTER COLUMN undone_at TYPE timestamp(6)"
  end

  def down do
    execute "ALTER TABLE activity_events ALTER COLUMN undone_at TYPE timestamp(0)"
  end
end
