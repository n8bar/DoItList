defmodule DoIt.Projects.ProjectMember do
  use Ecto.Schema
  import Ecto.Changeset

  alias DoIt.Accounts.User
  alias DoIt.Projects.Project

  @roles ~w(owner editor viewer)

  schema "project_members" do
    field :role, :string

    belongs_to :project, Project
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  def roles, do: @roles

  def changeset(member, attrs) do
    member
    |> cast(attrs, [:project_id, :user_id, :role])
    |> validate_required([:project_id, :user_id, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:project_id, :user_id])
  end
end
