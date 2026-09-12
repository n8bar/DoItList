defmodule DoIt.Repo.Migrations.CreateImportDeclarations do
  use Ecto.Migration

  # m03.04 2.8.10: an Initiative's first-import declaration — the structured
  # statement the MCP adapter demands and validates arithmetically (source
  # item total, completed count, exclusion sum + verbatim reasons, ordering
  # scheme). One row per Initiative, TTL-free: the declaration binds the whole
  # first import and stays as the on-record statement.
  def change do
    create table(:import_declarations) do
      add :initiative_id, references(:initiatives, on_delete: :delete_all), null: false
      add :source_total, :integer, null: false
      add :source_completed, :integer, null: false
      add :excluded_count, :integer, null: false, default: 0
      add :exclusions, :text
      add :ordering, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:import_declarations, [:initiative_id])
  end
end
