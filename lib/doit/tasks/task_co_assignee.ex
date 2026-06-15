defmodule DoIt.Tasks.TaskCoAssignee do
  @moduledoc """
  A co-assignee membership on a task (m02.05 item 13) — the additive,
  ordered list alongside the task's primary `assignee_id`. Order is always
  manual; `sort_order` position IS the promotion order.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias DoIt.Tasks.Task
  alias DoIt.Accounts.User

  schema "task_co_assignees" do
    field :sort_order, :integer, default: 0

    belongs_to :task, Task
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  def changeset(co, attrs) do
    co
    |> cast(attrs, [:task_id, :user_id, :sort_order])
    |> validate_required([:task_id, :user_id, :sort_order])
    |> unique_constraint([:task_id, :user_id])
  end
end
