defmodule DoIt.Repo.Migrations.AddTaskDisplayPrefs do
  use Ecto.Migration

  # m02.04 § Display elements grows a task-attribute show/hide list (operator
  # ask). All shown by default; "progress" covers the checkbox + the bar.
  def change do
    alter table(:user_preferences) do
      add :show_task_priority, :boolean, null: false, default: true
      add :show_task_assignee, :boolean, null: false, default: true
      add :show_task_progress, :boolean, null: false, default: true
      add :show_task_count, :boolean, null: false, default: true
    end
  end
end
