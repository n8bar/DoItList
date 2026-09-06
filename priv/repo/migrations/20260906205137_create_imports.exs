defmodule DoIt.Repo.Migrations.CreateImports do
  use Ecto.Migration

  # m03.04 2.3.5: the idempotency record for `POST /api/v1/imports`. One row per
  # (target, source text) once an apply commits; a repeat apply of the SAME text
  # into the SAME target replays the stored 200 body instead of importing twice.
  #
  # The target is stored structurally rather than as an opaque key so the lookup
  # can be scoped per kind: an existing Initiative/Task keys on the target alone
  # (any user who passes authz replays it), while a NEW-Initiative import — whose
  # target is just a requested name — also keys on the acting user.
  #
  # Rows are kept indefinitely: unlike an Idempotency-Key retry window, "this
  # document already went into this tree" is a permanent fact.
  def change do
    create table(:imports) do
      add :source_hash, :string, null: false
      add :target_kind, :string, null: false
      add :target_id, :integer
      add :target_name, :text
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :initiative_id, references(:initiatives, on_delete: :delete_all), null: false
      add :response, :map, null: false

      timestamps(type: :utc_datetime)
    end

    # NULLS NOT DISTINCT (Postgres 15+) so target_id/target_name being null on one
    # kind still collides — without it every new-Initiative row (target_id null)
    # would be unique regardless of name.
    create unique_index(
             :imports,
             [:target_kind, :target_id, :target_name, :user_id, :source_hash],
             name: :imports_target_source_index,
             nulls_distinct: false
           )

    create index(:imports, [:initiative_id])
  end
end
