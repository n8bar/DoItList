defmodule DoIt.Repo.Migrations.DropTasksWeight do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      remove :weight, :decimal, precision: 8, scale: 2, null: false, default: 1.0
    end
  end
end
