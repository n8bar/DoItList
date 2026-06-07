defmodule DoIt.Initiatives.Initiative do
  use Ecto.Schema
  import Ecto.Changeset

  alias DoIt.Accounts.User
  alias DoIt.Initiatives.InitiativeMember
  alias DoIt.Tasks.Task

  schema "initiatives" do
    field :name, :string
    field :description, :string
    field :my_role, :string, virtual: true
    # Loaded from the root task for list views: subtitle (its title) and the
    # rolled-up progress (its computed_progress).
    field :subtitle, :string, virtual: true
    field :progress, :integer, virtual: true

    belongs_to :owner, User
    # The system-managed root task: the Initiative IS this task (its title is the
    # Initiative's optional subtitle, its children are the rendered tree). Not a
    # tree row. See m02.03 worklist 5.
    belongs_to :root_task, Task
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
