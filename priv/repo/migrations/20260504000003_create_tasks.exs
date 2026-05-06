defmodule DoIt.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  def change do
    create table(:tasks) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :parent_id, references(:tasks, on_delete: :delete_all)
      add :title, :string, null: false, size: 200
      add :description, :text
      add :status, :string, null: false, default: "open", size: 16
      add :priority, :string, null: false, default: "normal", size: 16
      add :manual_progress, :integer, null: false, default: 0
      add :computed_progress, :integer, null: false, default: 0
      add :weight, :decimal, precision: 8, scale: 2, null: false, default: 1.0
      add :assignee_id, references(:users, on_delete: :nilify_all)
      add :sort_order, :integer, null: false, default: 0
      add :created_by_id, references(:users, on_delete: :nilify_all)
      add :updated_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:tasks, [:project_id])
    create index(:tasks, [:parent_id])
    create index(:tasks, [:assignee_id])
  end
end
