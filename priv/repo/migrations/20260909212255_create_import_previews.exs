defmodule DoIt.Repo.Migrations.CreateImportPreviews do
  use Ecto.Migration

  # m03.04 6.7: a stored import preview, so an agent can apply one by id
  # instead of resending the source document. One row per (access token,
  # target Initiative — null for a new one); a newer preview for the same key
  # replaces the row, an apply deletes it, and `expires_at` retires unapplied
  # ones (reaped lazily when that token stores its next preview).
  #
  # The id is a random base64url string, not a serial, so a preview can't be
  # guessed; the token scope keeps one token from applying another's preview.
  def change do
    create table(:import_previews, primary_key: false) do
      add :id, :string, primary_key: true
      add :api_token_id, references(:api_tokens, on_delete: :delete_all), null: false
      add :initiative_id, references(:initiatives, on_delete: :delete_all)
      add :initiative_version, :integer
      add :target_kind, :string, null: false
      add :target_id, :integer
      add :target_name, :text
      add :text, :text, null: false
      add :filename, :string
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    # NULLS NOT DISTINCT so every new-Initiative preview (initiative_id null)
    # for a token shares one key, like the existing-Initiative ones do.
    create unique_index(:import_previews, [:api_token_id, :initiative_id],
             name: :import_previews_token_target_index,
             nulls_distinct: false
           )

    create index(:import_previews, [:initiative_id])
  end
end
