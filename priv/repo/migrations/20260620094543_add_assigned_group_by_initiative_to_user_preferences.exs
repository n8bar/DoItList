defmodule DoIt.Repo.Migrations.AddAssignedGroupByInitiativeToUserPreferences do
  use Ecto.Migration

  def change do
    # Group-by-Initiative toggle for the Assigned-to-Me page (m02.08 worklist 1
    # item 6) — persistent and account-following, same pattern as the index
    # sort prefs. Off by default = a flat list.
    alter table(:user_preferences) do
      add :assigned_group_by_initiative, :boolean, null: false, default: false
    end
  end
end
