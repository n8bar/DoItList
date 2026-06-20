defmodule DoIt.Initiatives.InitiativeMember do
  use Ecto.Schema
  import Ecto.Changeset

  alias DoIt.Accounts.User
  alias DoIt.Initiatives.Initiative

  @roles ~w(owner editor viewer)

  schema "initiative_members" do
    field :role, :string
    # The member's manual drag order on the Initiatives index (m02.04 §2.6).
    # Set programmatically (Initiatives.set_index_order/2), never cast.
    field :sort_order, :integer
    # Per-user archive + hide (m02.08 worklist 4): both move an Initiative out
    # of this member's active list without touching anyone else's view.
    # `archived_at` → restorable Archived list; `hidden_at` → a lighter "off my
    # dashboard" hide. The Assigned-to-Me query filters on both.
    field :archived_at, :utc_datetime
    field :hidden_at, :utc_datetime

    belongs_to :initiative, Initiative
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  def roles, do: @roles

  def changeset(member, attrs) do
    member
    |> cast(attrs, [:initiative_id, :user_id, :role, :archived_at, :hidden_at])
    |> validate_required([:initiative_id, :user_id, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:initiative_id, :user_id])
  end
end
