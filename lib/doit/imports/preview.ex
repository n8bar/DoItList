defmodule DoIt.Imports.Preview do
  @moduledoc """
  One stored import preview (m03.04 6.7) — the source document and target a
  `preview: true` request was answered for, kept so the caller can apply it by
  `preview_id` instead of resending the text.

  A row belongs to the access token that previewed and to one target: an
  existing Initiative (`initiative_id`, with the `initiative_version` seen at
  preview time so a moved target is refused as stale) or a new one
  (`initiative_id` nil). `target_kind` / `target_id` / `target_name` store the
  request's target the same way `DoIt.Imports.Import` does, so the apply
  rebuilds exactly the target that was previewed.

  `line_offset` is how many whole-document lines precede a `section` preview's
  slice — the one fact the slice itself lost, and what lets the apply report
  `items` lines in the document the caller holds (6.12.3). A whole-document
  preview stores 0.

  The id is a random base64url string (`generate_id/0`); `api_token_id` is set
  programmatically, never cast.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "import_previews" do
    field :initiative_version, :integer
    field :target_kind, :string
    field :target_id, :integer
    field :target_name, :string
    field :text, :string
    field :filename, :string
    field :line_offset, :integer, default: 0
    field :expires_at, :utc_datetime

    belongs_to :api_token, DoIt.Accounts.ApiToken
    belongs_to :initiative, DoIt.Initiatives.Initiative

    timestamps(type: :utc_datetime)
  end

  @doc "An unguessable preview id: 18 random bytes, base64url without padding."
  def generate_id, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  @doc "Changeset for a preview row; `api_token_id` and `id` ride on the struct."
  def changeset(preview, attrs) do
    preview
    |> cast(attrs, [
      :initiative_id,
      :initiative_version,
      :target_kind,
      :target_id,
      :target_name,
      :text,
      :filename,
      :line_offset,
      :expires_at
    ])
    |> validate_required([:target_kind, :text, :expires_at])
    |> validate_inclusion(:target_kind, DoIt.Imports.Import.kinds())
  end
end
