defmodule DoIt.Tasks.CommentVersion do
  @moduledoc """
  A prior version of a comment's body (m02.08 worklist 3 item 2) — captured
  before an edit overwrites the live `body`, so the edit popup can surface
  earlier text. Write-once history: only an `inserted_at`.

  Schema only at this stage — the edit/delete lifecycle lands with a later
  agent.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias DoIt.Tasks.Comment

  schema "comment_versions" do
    field :body, :string

    belongs_to :comment, Comment

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(version, attrs) do
    version
    |> cast(attrs, [:comment_id, :body])
    |> validate_required([:comment_id, :body])
  end
end
