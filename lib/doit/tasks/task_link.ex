defmodule DoIt.Tasks.TaskLink do
  @moduledoc """
  A task->task cross-reference (m03.01 worklist 4) — a "see that other task"
  link.

  Anchored on the two **stable** task ids (`source_task_id` -> `target_task_id`),
  never a position or index, so a link **survives reorder/reparent** of either
  endpoint. The reference is rendered with the target's **live** index label
  (m02.07) computed at read time, so it never rots when the tree changes.

  A unique index on `(source_task_id, target_task_id)` dedupes; the FKs cascade
  on permanent delete (the link follows its endpoints). Soft-deleted (Trashed)
  endpoints keep the row but hide the link from reads until restore — see the
  migration and `DoIt.Tasks.list_links_for_initiative/1`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias DoIt.Tasks.Task

  schema "task_links" do
    belongs_to :source_task, Task
    belongs_to :target_task, Task

    timestamps(type: :utc_datetime)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:source_task_id, :target_task_id])
    |> validate_required([:source_task_id, :target_task_id])
    # Both endpoints are FKs into `tasks`. Declared as foreign_key_constraint (not
    # check_constraint) so a violation — a target/source that vanished mid-batch —
    # comes back as {:error, changeset}, a clean per-op error that ROLLS THE BATCH
    # back, rather than raising Ecto.ConstraintError out of the Multi.
    |> foreign_key_constraint(:source_task_id,
      message: "references a task that no longer exists"
    )
    |> foreign_key_constraint(:target_task_id,
      message: "references a task that no longer exists"
    )
    |> unique_constraint([:source_task_id, :target_task_id],
      message: "is already linked from this task"
    )
  end
end
