defmodule DoIt.Repo.Migrations.CreateCommentVersions do
  use Ecto.Migration

  def change do
    # Comment edit history (m02.08 worklist 3 item 2). Each row stores a
    # comment's PRIOR body before an edit replaced it, so the edit popup can
    # surface earlier versions. Table/schema only here — the edit/delete
    # lifecycle + UI land with a later agent.
    create table(:comment_versions) do
      add :comment_id, references(:comments, on_delete: :delete_all), null: false
      add :body, :text, null: false

      # History rows are write-once: only an inserted_at, no updated_at.
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:comment_versions, [:comment_id])

    # Soft-delete "who" for comments (m02.08 worklist 3 item 2). `comments`
    # already carries `deleted_at` (m02.06 item 14.5); this records the actor.
    # Column only — the delete UI / tombstone land with a later agent.
    alter table(:comments) do
      add :deleted_by_id, references(:users, on_delete: :nilify_all)
    end
  end
end
