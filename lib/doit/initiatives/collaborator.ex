defmodule DoIt.Initiatives.Collaborator do
  @moduledoc """
  A persistent "people I've worked with" edge (m02.05 item 12.10). Directional:
  `user_id` has shared an Initiative with `collaborator_id`. Recorded on
  co-membership (both directions), and — unlike `InitiativeMember` — never
  removed when a membership ends, so the Collaborators pane keeps past
  collaborators. Pruned only by an explicit `remove_collaborator/2` (item 12.11).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias DoIt.Accounts.User

  schema "collaborators" do
    belongs_to :user, User
    belongs_to :collaborator, User

    timestamps(type: :utc_datetime)
  end

  def changeset(collaborator, attrs) do
    collaborator
    |> cast(attrs, [:user_id, :collaborator_id])
    |> validate_required([:user_id, :collaborator_id])
    |> unique_constraint([:user_id, :collaborator_id])
  end
end
