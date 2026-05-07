defmodule DoIt.Repo.Migrations.RenameOrchardsToInitiatives do
  @moduledoc """
  Renames the `orchards` and `orchard_members` tables (and the `orchard_id`
  foreign-key columns on `orchard_members`, `tasks`, and `activity_events`)
  to use the `initiative` vocabulary. Auto-generated indexes, foreign-key
  constraints, and sequences are renamed for cleanliness. Reversible.
  No data is moved or dropped.
  """
  use Ecto.Migration

  def change do
    # Tables.
    rename table(:orchards), to: table(:initiatives)
    rename table(:orchard_members), to: table(:initiative_members)

    # Foreign-key columns (table is the *new* name at this point).
    rename table(:initiative_members), :orchard_id, to: :initiative_id
    rename table(:tasks), :orchard_id, to: :initiative_id
    rename table(:activity_events), :orchard_id, to: :initiative_id

    # Primary-key indexes.
    execute(
      "ALTER INDEX orchards_pkey RENAME TO initiatives_pkey",
      "ALTER INDEX initiatives_pkey RENAME TO orchards_pkey"
    )
    execute(
      "ALTER INDEX orchard_members_pkey RENAME TO initiative_members_pkey",
      "ALTER INDEX initiative_members_pkey RENAME TO orchard_members_pkey"
    )

    # Other indexes.
    execute(
      "ALTER INDEX orchards_owner_id_index RENAME TO initiatives_owner_id_index",
      "ALTER INDEX initiatives_owner_id_index RENAME TO orchards_owner_id_index"
    )
    execute(
      "ALTER INDEX orchard_members_orchard_id_user_id_index RENAME TO initiative_members_initiative_id_user_id_index",
      "ALTER INDEX initiative_members_initiative_id_user_id_index RENAME TO orchard_members_orchard_id_user_id_index"
    )
    execute(
      "ALTER INDEX orchard_members_user_id_index RENAME TO initiative_members_user_id_index",
      "ALTER INDEX initiative_members_user_id_index RENAME TO orchard_members_user_id_index"
    )
    execute(
      "ALTER INDEX tasks_orchard_id_index RENAME TO tasks_initiative_id_index",
      "ALTER INDEX tasks_initiative_id_index RENAME TO tasks_orchard_id_index"
    )
    execute(
      "ALTER INDEX activity_events_orchard_id_index RENAME TO activity_events_initiative_id_index",
      "ALTER INDEX activity_events_initiative_id_index RENAME TO activity_events_orchard_id_index"
    )

    # Foreign-key constraints.
    execute(
      "ALTER TABLE initiatives RENAME CONSTRAINT orchards_owner_id_fkey TO initiatives_owner_id_fkey",
      "ALTER TABLE initiatives RENAME CONSTRAINT initiatives_owner_id_fkey TO orchards_owner_id_fkey"
    )
    execute(
      "ALTER TABLE initiative_members RENAME CONSTRAINT orchard_members_orchard_id_fkey TO initiative_members_initiative_id_fkey",
      "ALTER TABLE initiative_members RENAME CONSTRAINT initiative_members_initiative_id_fkey TO orchard_members_orchard_id_fkey"
    )
    execute(
      "ALTER TABLE initiative_members RENAME CONSTRAINT orchard_members_user_id_fkey TO initiative_members_user_id_fkey",
      "ALTER TABLE initiative_members RENAME CONSTRAINT initiative_members_user_id_fkey TO orchard_members_user_id_fkey"
    )
    execute(
      "ALTER TABLE tasks RENAME CONSTRAINT tasks_orchard_id_fkey TO tasks_initiative_id_fkey",
      "ALTER TABLE tasks RENAME CONSTRAINT tasks_initiative_id_fkey TO tasks_orchard_id_fkey"
    )
    execute(
      "ALTER TABLE activity_events RENAME CONSTRAINT activity_events_orchard_id_fkey TO activity_events_initiative_id_fkey",
      "ALTER TABLE activity_events RENAME CONSTRAINT activity_events_initiative_id_fkey TO activity_events_orchard_id_fkey"
    )

    # Sequences.
    execute(
      "ALTER SEQUENCE orchards_id_seq RENAME TO initiatives_id_seq",
      "ALTER SEQUENCE initiatives_id_seq RENAME TO orchards_id_seq"
    )
    execute(
      "ALTER SEQUENCE orchard_members_id_seq RENAME TO initiative_members_id_seq",
      "ALTER SEQUENCE initiative_members_id_seq RENAME TO orchard_members_id_seq"
    )
  end
end
