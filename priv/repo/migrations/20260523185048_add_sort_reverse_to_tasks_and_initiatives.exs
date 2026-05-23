defmodule DoIt.Repo.Migrations.AddSortReverseToTasksAndInitiatives do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :sort_reverse, :boolean, null: false, default: false
    end

    alter table(:initiatives) do
      add :sort_reverse, :boolean, null: false, default: false
    end
  end
end
