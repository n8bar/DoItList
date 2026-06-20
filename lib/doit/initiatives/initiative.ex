defmodule DoIt.Initiatives.Initiative do
  use Ecto.Schema
  import Ecto.Changeset

  alias DoIt.Accounts.User
  alias DoIt.Initiatives.InitiativeMember
  alias DoIt.Tasks.Task

  schema "initiatives" do
    field :name, :string
    field :description, :string
    field :progress_calc, :string, default: "leaf_average"
    # m02.05 item 12.1: when on, clearing a task's primary assignee backfills
    # from the co-assignee list (first current member in manual order).
    field :auto_promote_co_assignees, :boolean, default: false
    # m02.05 item 12.6: when on, a viewer who is a task's direct (primary)
    # assignee leads its subtree — edits progress/comments and staffs
    # descendants from the led task's co-assignee pool.
    field :viewer_plus, :boolean, default: true
    # m02.07 item 1.7: positional task-index style for this tree (per-Initiative,
    # not per-account). "none" = no index shown (default). See DoIt.Tasks.Index.
    field :index_style, :string, default: "none"
    # Trash (m02.06): set when the Initiative is soft-deleted; nil = live.
    field :trashed_at, :utc_datetime
    field :my_role, :string, virtual: true
    # The viewing member's manual index order (initiative_members.sort_order).
    field :my_sort_order, :integer, virtual: true
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
    |> cast(attrs, [
      :name,
      :description,
      :progress_calc,
      :auto_promote_co_assignees,
      :viewer_plus,
      :index_style,
      :owner_id
    ])
    |> validate_required([:name, :owner_id])
    |> validate_inclusion(:progress_calc, ~w(leaf_average single_level))
    |> validate_inclusion(:index_style, DoIt.Tasks.Index.styles())
    |> validate_length(:name, min: 1, max: 120)
    |> validate_length(:description, max: 4000)
  end
end
