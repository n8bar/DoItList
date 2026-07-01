defmodule DoitMcp.Tools.UpdateTask do
  @moduledoc """
  Edit a task's plain fields (title, description, priority, assignee,
  manual progress). This tool only edits plain fields — completion
  (`complete_task`), moves (`move_task`), and co-assignees
  (`set_task_co_assignees`) are separate tools, matching the API's
  "one concern per update" rule.
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
  end

  def execute(params, frame) do
    data =
      params
      |> Map.take([
        :title,
        :description,
        :priority,
        :assignee_id,
        :manual_progress
      ])
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    [%{"op" => "update", "type" => "task", "id" => params.task_id, "data" => data}]
    |> Client.operations()
    |> then(&ToolResult.reply(frame, &1))
  end
end
