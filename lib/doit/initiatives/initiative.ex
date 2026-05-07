defmodule DoIt.Initiatives.Initiative do
  use Ecto.Schema
  import Ecto.Changeset

  alias DoIt.Accounts.User
  alias DoIt.Initiatives.InitiativeMember
  alias DoIt.Tasks.Task

  schema "initiatives" do
    field :name, :string
    field :description, :string

    belongs_to :owner, User
    has_many :memberships, InitiativeMember
    has_many :tasks, Task

    timestamps(type: :utc_datetime)
  end

  def changeset(initiative, attrs) do
    initiative
    |> cast(attrs, [:name, :description, :owner_id])
    |> validate_required([:name, :owner_id])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_length(:description, max: 4000)
  end
end
