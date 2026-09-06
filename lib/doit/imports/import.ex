defmodule DoIt.Imports.Import do
  @moduledoc """
  One committed text import — the idempotency record behind
  `POST /api/v1/imports` (m03.04 2.3.5).

  A row is written only after an apply's every batch commits, and it stores the
  exact 200 body that apply sent. A later apply of the SAME source text into the
  SAME target finds this row and replays that body (plus `"replayed": true`)
  instead of importing the document a second time.

  The **target** is stored structurally — `target_kind` (`"new_initiative" |
  "initiative" | "task"`), `target_id` for an existing Initiative or parent
  Task, `target_name` for the requested name of a new Initiative — so the
  lookup can scope per kind (see `DoIt.Imports.fetch/2`). `initiative_id` is the
  Initiative the import landed in, whichever kind the target was.

  `user_id` is set programmatically on the struct, never cast.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(new_initiative initiative task)

  schema "imports" do
    field :source_hash, :string
    field :target_kind, :string
    field :target_id, :integer
    field :target_name, :string
    field :response, :map

    belongs_to :user, DoIt.Accounts.User
    belongs_to :initiative, DoIt.Initiatives.Initiative

    timestamps(type: :utc_datetime)
  end

  @doc "The accepted `target_kind` values."
  def kinds, do: @kinds

  @doc """
  Changeset for an import record. `user_id` is set programmatically on the
  struct — never cast — for security.
  """
  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :source_hash,
      :target_kind,
      :target_id,
      :target_name,
      :initiative_id,
      :response
    ])
    |> validate_required([:source_hash, :target_kind, :initiative_id, :response])
    |> validate_inclusion(:target_kind, @kinds)
    |> unique_constraint([:target_kind, :target_id, :target_name, :user_id, :source_hash],
      name: :imports_target_source_index
    )
  end
end
