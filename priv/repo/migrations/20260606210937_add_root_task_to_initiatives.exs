defmodule DoIt.Repo.Migrations.AddRootTaskToInitiatives do
  use Ecto.Migration

  # Each Initiative gains one system-managed root task. Today's top-level tasks
  # (parent_id IS NULL) become its children, so going forward `parent_id IS NULL`
  # identifies exactly the root task. The root task is not rendered as a tree row;
  # the Initiative IS its root task (m02.03 worklist 5).

  def up do
    alter table(:initiatives) do
      add :root_task_id, references(:tasks, on_delete: :nilify_all)
    end

    flush()

    %{rows: initiatives} = repo().query!("SELECT id, owner_id FROM initiatives")

    Enum.each(initiatives, fn [init_id, owner_id] ->
      # Title defaults to a single space: the root task's title doubles as the
      # Initiative's optional subtitle (worklist 5), and the column is min-1.
      %{rows: [[root_id]]} =
        repo().query!(
          """
          INSERT INTO tasks
            (initiative_id, parent_id, title, status, priority, manual_progress,
             computed_progress, weight, sort_order, sort_reverse, created_by_id,
             inserted_at, updated_at)
          VALUES ($1, NULL, ' ', 'open', 'normal', 0, 0, 1.0, 0, false, $2, now(), now())
          RETURNING id
          """,
          [init_id, owner_id]
        )

      repo().query!(
        "UPDATE tasks SET parent_id = $1 WHERE initiative_id = $2 AND parent_id IS NULL AND id <> $1",
        [root_id, init_id]
      )

      repo().query!("UPDATE initiatives SET root_task_id = $1 WHERE id = $2", [root_id, init_id])
    end)

    # Seed each root's computed_progress from its children's effective progress
    # (branch → computed_progress, leaf → manual_progress), weighted. Keeps
    # existing Initiative aggregates accurate without waiting for a mutation.
    repo().query!("""
    UPDATE tasks r
    SET computed_progress = COALESCE((
      SELECT round(
        sum(
          (CASE WHEN EXISTS (SELECT 1 FROM tasks gc WHERE gc.parent_id = c.id)
                THEN c.computed_progress ELSE c.manual_progress END) * c.weight
        ) / NULLIF(sum(c.weight), 0)
      )
      FROM tasks c WHERE c.parent_id = r.id
    ), 0)
    WHERE r.id IN (SELECT root_task_id FROM initiatives WHERE root_task_id IS NOT NULL)
    """)
  end

  def down do
    # Lift each root's children back to top level, then drop the roots.
    execute(
      "UPDATE tasks c SET parent_id = NULL FROM initiatives i WHERE c.parent_id = i.root_task_id"
    )

    execute(
      "DELETE FROM tasks WHERE id IN (SELECT root_task_id FROM initiatives WHERE root_task_id IS NOT NULL)"
    )

    alter table(:initiatives) do
      remove :root_task_id
    end
  end
end
