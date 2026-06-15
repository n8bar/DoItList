defmodule DoIt.Repo.Migrations.CreateTaskCoAssignees do
  use Ecto.Migration

  # m02.05 item 13 — co-assignees. The primary stays on `tasks.assignee_id`;
  # this is the additive, ORDERED co-assignee list. Order is always manual
  # (position = promotion order), held in `sort_order`.
  def change do
    create table(:task_co_assignees) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :sort_order, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:task_co_assignees, [:task_id, :user_id])
    create index(:task_co_assignees, [:user_id])
  end
end
