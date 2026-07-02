defmodule DoIt.Tasks.Task do
  use Ecto.Schema
  import Ecto.Changeset

  alias DoIt.Accounts.User
  alias DoIt.Initiatives.Initiative
  alias DoIt.Tasks.{Comment, Task}

  @statuses ~w(open in_progress done)
  @priorities ~w(low normal high)
  @sort_modes ~w(manual alphabetical completion priority created updated)

  schema "tasks" do
    field :title, :string
    field :description, :string
    field :status, :string, default: "open"
    field :priority, :string, default: "normal"
    field :manual_progress, :integer, default: 0
    field :computed_progress, :integer, default: 0
    field :sort_order, :integer, default: 0
    field :sort_mode, :string
    field :sort_reverse, :boolean, default: false
    # Soft-delete (m02.06): a deleted task keeps its row (id, comments,
    # co-assignees, events all preserved) so undo / Trash can restore it. Set
    # programmatically — never cast from user params. Reads filter it out.
    field :deleted_at, :utc_datetime
    # Co-assignees attached for tree/lineage rendering (m02.05 items 13/16):
    # the total count plus a capped list of co-assignee users for the
    # overlapping-avatar chip — so the row needs no per-row query.
    field :co_assignee_count, :integer, virtual: true, default: 0
    field :co_assignee_users, {:array, :map}, virtual: true, default: []
    # Assigned-to-Me read (m02.08 worklist 1): how the viewing user is on this
    # task (:primary / :co), the owning Initiative's name + badge mode, the two
    # subtree counts, and whether it surfaced only via a reveal toggle.
    field :assigned_as, Ecto.Enum, values: [:primary, :co], virtual: true
    field :initiative_name, :string, virtual: true
    field :progress_calc, :string, virtual: true
    field :child_count, :integer, virtual: true, default: 0
    field :assigned_leaf_count, :integer, virtual: true, default: 1
    field :from_archived_or_hidden, :boolean, virtual: true, default: false
    # Marks the first row of an Initiative group in the Assigned-to-Me list so a
    # streamed row can render its header without peeking at neighbors (item 1.6).
    field :group_start?, :boolean, virtual: true, default: false

    belongs_to :initiative, Initiative
    belongs_to :parent, Task
    belongs_to :assignee, User
    belongs_to :created_by, User
    belongs_to :updated_by, User

    has_many :children, Task, foreign_key: :parent_id
    has_many :comments, Comment

    # Ordered co-assignee list (m02.05 item 13); primary stays on assignee_id.
    has_many :co_assignee_links, DoIt.Tasks.TaskCoAssignee, preload_order: [asc: :sort_order]

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses
  def priorities, do: @priorities
  def sort_modes, do: @sort_modes

  def create_changeset(task, attrs) do
    task
    |> cast(attrs, [
      :title,
      :description,
      :status,
      :priority,
      :manual_progress,
      :sort_order,
      :sort_mode,
      :sort_reverse,
      :initiative_id,
      :parent_id,
      :assignee_id,
      :created_by_id,
      :updated_by_id
    ])
    |> validate_required([:title, :initiative_id, :created_by_id])
    |> validate_length(:title, min: 1, max: 200)
    |> validate_length(:description, max: 8000)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:priority, @priorities)
    |> validate_inclusion(:sort_mode, [nil | @sort_modes])
    |> validate_number(:manual_progress, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
  end

  def update_changeset(task, attrs) do
    task
    |> cast(attrs, [
      :title,
      :description,
      :status,
      :priority,
      :manual_progress,
      :sort_order,
      :sort_mode,
      :sort_reverse,
      :parent_id,
      :assignee_id,
      :updated_by_id
    ])
    |> validate_required([:title])
    |> validate_length(:title, min: 1, max: 200)
    |> validate_length(:description, max: 8000)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:priority, @priorities)
    |> validate_inclusion(:sort_mode, [nil | @sort_modes])
    |> validate_number(:manual_progress, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
  end
end
