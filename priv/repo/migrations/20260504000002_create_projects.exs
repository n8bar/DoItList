defmodule DoIt.Repo.Migrations.CreateProjects do
  use Ecto.Migration

  def change do
    create table(:projects) do
      add :name, :string, null: false, size: 120
      add :description, :text
      add :owner_id, references(:users, on_delete: :restrict), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:projects, [:owner_id])

    create table(:project_members) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :role, :string, null: false, size: 16

      timestamps(type: :utc_datetime)
    end

    create unique_index(:project_members, [:project_id, :user_id])
    create index(:project_members, [:user_id])
  end
end
