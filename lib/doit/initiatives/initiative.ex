defmodule DoIt.Initiatives.Initiative do
  use Ecto.Schema
  import Ecto.Changeset

  alias DoIt.Accounts.User
  alias DoIt.Initiatives.InitiativeMember
  alias DoIt.Tasks.Task

  @sort_modes ~w(manual alphabetical completion computed_progress priority created updated)

  schema "initiatives" do
    field :name, :string
    field :description, :string
    field :sort_mode, :string
    field :sort_reverse, :boolean, default: false
    field :my_role, :string, virtual: true

    belongs_to :owner, User
    has_many :memberships, InitiativeMember
    has_many :tasks, Task

    timestamps(type: :utc_datetime)
  end

  def sort_modes, do: @sort_modes

  def changeset(initiative, attrs) do
    initiative
    |> cast(attrs, [:name, :description, :sort_mode, :sort_reverse, :owner_id])
    |> validate_required([:name, :owner_id])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_length(:description, max: 4000)
    |> validate_inclusion(:sort_mode, [nil | @sort_modes])
  end
end
