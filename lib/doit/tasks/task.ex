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
    # Count of co-assignees (m02.05 item 13), attached for tree/lineage
    # rendering so the row's "+N" chip hint needs no per-row query.
    field :co_assignee_count, :integer, virtual: true, default: 0

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

  def computed_progress_changeset(task, computed_progress) do
    change(task, computed_progress: computed_progress)
  end
end
