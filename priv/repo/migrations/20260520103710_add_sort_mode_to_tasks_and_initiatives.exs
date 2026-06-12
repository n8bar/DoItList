defmodule DoIt.Repo.Migrations.AddSortModeToTasksAndInitiatives do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :sort_mode, :string, size: 32
    end

    alter table(:initiatives) do
      add :sort_mode, :string, size: 32
    end
  end
end
