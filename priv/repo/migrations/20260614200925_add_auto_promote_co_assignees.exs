defmodule DoIt.Repo.Migrations.AddAutoPromoteCoAssignees do
  use Ecto.Migration

  # m02.05 item 13: the per-Initiative "Auto-promote co-assignees" setting
  # (default off), plus its My-Initiative-Defaults seed on user_preferences.
  def change do
    alter table(:initiatives) do
      add :auto_promote_co_assignees, :boolean, null: false, default: false
    end

    alter table(:user_preferences) do
      add :initiative_auto_promote, :boolean, null: false, default: false
    end
  end
end
