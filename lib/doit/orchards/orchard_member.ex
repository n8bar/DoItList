defmodule DoIt.Orchards.OrchardMember do
  use Ecto.Schema
  import Ecto.Changeset

  alias DoIt.Accounts.User
  alias DoIt.Orchards.Orchard

  @roles ~w(owner editor viewer)

  schema "orchard_members" do
    field :role, :string

    belongs_to :orchard, Orchard
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  def roles, do: @roles

  def changeset(member, attrs) do
    member
    |> cast(attrs, [:orchard_id, :user_id, :role])
    |> validate_required([:orchard_id, :user_id, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:orchard_id, :user_id])
  end
end
