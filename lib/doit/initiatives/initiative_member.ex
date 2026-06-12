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

    belongs_to :initiative, Initiative
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  def roles, do: @roles

  def changeset(member, attrs) do
    member
    |> cast(attrs, [:initiative_id, :user_id, :role])
    |> validate_required([:initiative_id, :user_id, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:initiative_id, :user_id])
  end
end
