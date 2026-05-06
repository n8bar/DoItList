defmodule DoIt.Tasks.Task do
  use Ecto.Schema
  import Ecto.Changeset

  alias DoIt.Accounts.User
  alias DoIt.Projects.Project
  alias DoIt.Tasks.{Comment, Task}

  @statuses ~w(open in_progress done)
  @priorities ~w(low normal high)

  schema "tasks" do
    field :title, :string
    field :description, :string
    field :status, :string, default: "open"
    field :priority, :string, default: "normal"
    field :manual_progress, :integer, default: 0
    field :computed_progress, :integer, default: 0
    field :weight, :decimal, default: Decimal.new("1.0")
    field :sort_order, :integer, default: 0

    belongs_to :project, Project
    belongs_to :parent, Task
    belongs_to :assignee, User
    belongs_to :created_by, User
    belongs_to :updated_by, User

    has_many :children, Task, foreign_key: :parent_id
    has_many :comments, Comment

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses
  def priorities, do: @priorities

  def create_changeset(task, attrs) do
    task
    |> cast(attrs, [
      :title,
      :description,
      :status,
      :priority,
      :manual_progress,
      :weight,
      :sort_order,
      :project_id,
      :parent_id,
      :assignee_id,
      :created_by_id,
      :updated_by_id
    ])
    |> validate_required([:title, :project_id, :created_by_id])
    |> validate_length(:title, min: 1, max: 200)
    |> validate_length(:description, max: 8000)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:priority, @priorities)
    |> validate_number(:manual_progress, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_weight()
  end

  def update_changeset(task, attrs) do
    task
    |> cast(attrs, [
      :title,
      :description,
      :status,
      :priority,
      :manual_progress,
      :weight,
      :sort_order,
      :parent_id,
      :assignee_id,
      :updated_by_id
    ])
    |> validate_required([:title])
    |> validate_length(:title, min: 1, max: 200)
    |> validate_length(:description, max: 8000)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:priority, @priorities)
    |> validate_number(:manual_progress, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_weight()
  end

  def computed_progress_changeset(task, computed_progress) do
    change(task, computed_progress: computed_progress)
  end

  defp validate_weight(changeset) do
    case get_field(changeset, :weight) do
      nil ->
        changeset

      %Decimal{} = w ->
        if Decimal.compare(w, Decimal.new(0)) == :gt do
          changeset
        else
          add_error(changeset, :weight, "must be greater than 0")
        end

      n when is_number(n) and n > 0 ->
        changeset

      _ ->
        add_error(changeset, :weight, "must be greater than 0")
    end
  end
end
