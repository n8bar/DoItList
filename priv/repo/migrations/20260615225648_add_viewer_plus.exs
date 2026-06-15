defmodule DoIt.Repo.Migrations.AddViewerPlus do
  use Ecto.Migration

  # m02.05 item 12.6: per-Initiative "Viewer+" setting (a viewer who is a
  # task's direct assignee leads its subtree), plus the per-user default that
  # seeds it on new Initiatives (§ My Initiative Defaults). Both default ON.
  def change do
    alter table(:initiatives) do
      add :viewer_plus, :boolean, null: false, default: true
    end

    alter table(:user_preferences) do
      add :initiative_viewer_plus, :boolean, null: false, default: true
    end
  end
end
