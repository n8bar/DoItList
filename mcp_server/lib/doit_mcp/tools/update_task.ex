defmodule DoitMcp.Tools.UpdateTask do
  @moduledoc """
  Update a task's title, description, priority, assignee, or manual progress. `title` and `description` accept `%<task_id>` cross-reference tokens. Always use `complete_task` for completion, `move_task` for parent or position changes, and `set_task_co_assignees` for co-assignees.

  Always pass the latest task `version` as `expected_version` unless overwriting any intervening change is acceptable. A stale version applies nothing and returns the current task; reconcile that record before retrying. Omitting `expected_version` writes unconditionally.

  When a pass updates multiple tasks, always use one `apply_operations` batch; never loop `update_task`.
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.{Client, ToolResult}

  schema do
    field(:task_id, :integer, required: true)
    field(:title, :string, required: false)
    field(:description, :string, required: false)
    field(:priority, :string, required: false)
    field(:assignee_id, :integer, required: false)
    field(:manual_progress, :integer, required: false)

    field(:expected_version, :integer,
      required: false,
      description:
        "Latest task `version`. Always provide it unless overwriting any intervening change is acceptable. A mismatch applies nothing and returns the current task; reconcile it before retrying. Omit only for an unconditional write"
    )
  end

  def execute(params, frame) do
    data =
      params
      |> Map.take([
        :title,
        :description,
        :priority,
        :assignee_id,
        :manual_progress,
        :expected_version
      ])
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    [%{"op" => "update", "type" => "task", "id" => params.task_id, "data" => data}]
    |> Client.operations()
    |> then(&ToolResult.reply(frame, &1))
  end
end
