defmodule DoIt.Repo.Migrations.RenameProjectsToOrchards do
  @moduledoc """
  Renames the `projects` and `project_members` tables (and the `project_id`
  foreign-key columns on `project_members`, `tasks`, and `activity_events`) to
  use the new `orchard` vocabulary. Also renames the auto-generated indexes,
  constraints, and sequences so the underlying schema reads cleanly. No data
  is moved or dropped.
  """
  use Ecto.Migration

  def change do
    # Tables.
    rename table(:projects), to: table(:orchards)
    rename table(:project_members), to: table(:orchard_members)

    # Foreign-key columns (table is the *new* name at this point).
    rename table(:orchard_members), :project_id, to: :orchard_id
    rename table(:tasks), :project_id, to: :orchard_id
    rename table(:activity_events), :project_id, to: :orchard_id

    # Primary-key indexes.
    execute(
      "ALTER INDEX projects_pkey RENAME TO orchards_pkey",
      "ALTER INDEX orchards_pkey RENAME TO projects_pkey"
    )

    execute(
      "ALTER INDEX project_members_pkey RENAME TO orchard_members_pkey",
      "ALTER INDEX orchard_members_pkey RENAME TO project_members_pkey"
    )

    # Other indexes.
    execute(
      "ALTER INDEX projects_owner_id_index RENAME TO orchards_owner_id_index",
      "ALTER INDEX orchards_owner_id_index RENAME TO projects_owner_id_index"
    )

    execute(
      "ALTER INDEX project_members_project_id_user_id_index RENAME TO orchard_members_orchard_id_user_id_index",
      "ALTER INDEX orchard_members_orchard_id_user_id_index RENAME TO project_members_project_id_user_id_index"
    )

    execute(
      "ALTER INDEX project_members_user_id_index RENAME TO orchard_members_user_id_index",
      "ALTER INDEX orchard_members_user_id_index RENAME TO project_members_user_id_index"
    )

    execute(
      "ALTER INDEX tasks_project_id_index RENAME TO tasks_orchard_id_index",
      "ALTER INDEX tasks_orchard_id_index RENAME TO tasks_project_id_index"
    )

    execute(
      "ALTER INDEX activity_events_project_id_index RENAME TO activity_events_orchard_id_index",
      "ALTER INDEX activity_events_orchard_id_index RENAME TO activity_events_project_id_index"
    )

    # Foreign-key constraints.
    execute(
      "ALTER TABLE orchards RENAME CONSTRAINT projects_owner_id_fkey TO orchards_owner_id_fkey",
      "ALTER TABLE orchards RENAME CONSTRAINT orchards_owner_id_fkey TO projects_owner_id_fkey"
    )

    execute(
      "ALTER TABLE orchard_members RENAME CONSTRAINT project_members_project_id_fkey TO orchard_members_orchard_id_fkey",
      "ALTER TABLE orchard_members RENAME CONSTRAINT orchard_members_orchard_id_fkey TO project_members_project_id_fkey"
    )

    execute(
      "ALTER TABLE orchard_members RENAME CONSTRAINT project_members_user_id_fkey TO orchard_members_user_id_fkey",
      "ALTER TABLE orchard_members RENAME CONSTRAINT orchard_members_user_id_fkey TO project_members_user_id_fkey"
    )

    execute(
      "ALTER TABLE tasks RENAME CONSTRAINT tasks_project_id_fkey TO tasks_orchard_id_fkey",
      "ALTER TABLE tasks RENAME CONSTRAINT tasks_orchard_id_fkey TO tasks_project_id_fkey"
    )

    execute(
      "ALTER TABLE activity_events RENAME CONSTRAINT activity_events_project_id_fkey TO activity_events_orchard_id_fkey",
      "ALTER TABLE activity_events RENAME CONSTRAINT activity_events_orchard_id_fkey TO activity_events_project_id_fkey"
    )

    # Sequences (auto-named on SERIAL/identity primary keys).
    execute(
      "ALTER SEQUENCE projects_id_seq RENAME TO orchards_id_seq",
      "ALTER SEQUENCE orchards_id_seq RENAME TO projects_id_seq"
    )

    execute(
      "ALTER SEQUENCE project_members_id_seq RENAME TO orchard_members_id_seq",
      "ALTER SEQUENCE orchard_members_id_seq RENAME TO project_members_id_seq"
    )
  end
end
