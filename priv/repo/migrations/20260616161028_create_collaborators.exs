defmodule DoIt.Repo.Migrations.CreateCollaborators do
  use Ecto.Migration

  def up do
    # Persistent "people I've worked with" (m02.05 item 12.10). Directional:
    # a row (user_id → collaborator_id) means user_id has shared an Initiative
    # with collaborator_id. Recorded on co-membership, never deleted when a
    # membership ends, so past collaborators stay in the pane.
    create table(:collaborators) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :collaborator_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:collaborators, [:user_id, :collaborator_id])
    create index(:collaborators, [:collaborator_id])

    # Backfill every current shared pair, both directions (item 12.10.3), so
    # existing collaborators persist from day one.
    execute("""
    INSERT INTO collaborators (user_id, collaborator_id, inserted_at, updated_at)
    SELECT DISTINCT m1.user_id, m2.user_id, NOW(), NOW()
    FROM initiative_members m1
    JOIN initiative_members m2
      ON m1.initiative_id = m2.initiative_id AND m1.user_id <> m2.user_id
    ON CONFLICT (user_id, collaborator_id) DO NOTHING
    """)
  end

  def down do
    drop table(:collaborators)
  end
end
