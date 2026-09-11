defmodule DoIt.Repo.Migrations.AddLineOffsetToImportPreviews do
  use Ecto.Migration

  # A section preview stores the slice, not the document it came from, so the
  # apply that follows it needs the one fact the slice lost: how many
  # whole-document lines precede it. Without it an applied preview would
  # report slice-relative lines and annotate the wrong lines of the caller's
  # file (m03.04 6.12.3).
  def change do
    alter table(:import_previews) do
      add :line_offset, :integer, null: false, default: 0
    end
  end
end
