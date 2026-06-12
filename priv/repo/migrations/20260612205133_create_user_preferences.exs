defmodule DoIt.Repo.Migrations.CreateUserPreferences do
  use Ecto.Migration

  # One row per user (m02.04 § User Preferences). Nil-valued sort/calc
  # columns mean "no preference — today's default behavior".
  def change do
    create table(:user_preferences) do
      add :user_id, references(:users, on_delete: :delete_all), null: false

      # Initiatives-index sort (item 2.6): mode/reverse of the index's
      # existing control. nil mode = the server default ("Recent").
      add :index_sort_mode, :string
      add :index_sort_reverse, :boolean, null: false, default: false

      # My Initiative Defaults (item 2.2) — seeded onto the new initiative's
      # root task (sort) and the initiative row (progress calc).
      add :initiative_sort_mode, :string
      add :initiative_sort_reverse, :boolean, null: false, default: false
      add :initiative_progress_calc, :string

      # My Task Defaults (item 2.3) — "match_parent" sentinels inherit.
      add :task_sort_mode, :string, null: false, default: "match_parent"
      add :task_priority, :string, null: false, default: "normal"
      add :task_assign_owner, :boolean, null: false, default: false

      # Display elements (item 2.4).
      add :show_task_activity, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_preferences, [:user_id])
  end
end
