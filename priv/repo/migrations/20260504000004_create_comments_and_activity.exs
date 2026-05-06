defmodule DoIt.Repo.Migrations.CreateCommentsAndActivity do
  use Ecto.Migration

  def change do
    create table(:comments) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :body, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:comments, [:task_id])

    create table(:activity_events) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :kind, :string, null: false, size: 60
      add :data, :map, null: false, default: %{}

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:activity_events, [:task_id])
    create index(:activity_events, [:project_id])
  end
end
