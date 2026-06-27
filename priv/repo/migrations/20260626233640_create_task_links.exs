defmodule DoIt.Repo.Migrations.CreateTaskLinks do
  use Ecto.Migration

  # m03.01 worklist 4.1 — task->task cross-references ("see that other task").
  #
  # A link is anchored on the two STABLE task row ids, never a position/index, so
  # it survives reorder/reparent of either endpoint; the displayed reference
  # resolves to the target's LIVE index label (m02.07) at render time, so it
  # never rots.
  #
  # on_delete: :delete_all — a link FOLLOWS its endpoints: when a task is
  # PERMANENTLY deleted (empty-Trash / hard delete) the FK cascade removes any
  # link touching it. A SOFT delete (Trash) only stamps `tasks.deleted_at`, so
  # the link row survives a trash/restore round-trip; the read surface HIDES a
  # link while either endpoint is soft-deleted (it has no live index label), and
  # the link reappears on restore.
  def change do
    create table(:task_links) do
      add :source_task_id, references(:tasks, on_delete: :delete_all), null: false
      add :target_task_id, references(:tasks, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    # Dedupe: at most one link per ordered (source, target) pair. The atomic op's
    # `add link` relies on this to reject a duplicate as a clean per-op error.
    create unique_index(:task_links, [:source_task_id, :target_task_id])
    # Incoming-reference lookups (`referenced_by`) scan by target.
    create index(:task_links, [:target_task_id])
  end
end
