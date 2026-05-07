defmodule DoIt.Orchards.Orchard do
  use Ecto.Schema
  import Ecto.Changeset

  alias DoIt.Accounts.User
  alias DoIt.Orchards.OrchardMember
  alias DoIt.Tasks.Task

  schema "orchards" do
    field :name, :string
    field :description, :string

    belongs_to :owner, User
    has_many :memberships, OrchardMember
    has_many :tasks, Task

    timestamps(type: :utc_datetime)
  end

  def changeset(orchard, attrs) do
    orchard
    |> cast(attrs, [:name, :description, :owner_id])
    |> validate_required([:name, :owner_id])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_length(:description, max: 4000)
  end
end
