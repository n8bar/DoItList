defmodule DoitMcp.Tools.SetTaskCoAssignees do
  @moduledoc """
  Replace a task's full co-assignee list in one call. Add/remove/reorder
  are all derived server-side from the diff against the task's current
  co-assignees — this tool always sends the complete target list.
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.{Client, ToolResult}

  schema do
    field(:task_id, :integer, required: true)
    field(:co_assignee_ids, {:list, :integer}, required: true)
  end

  def execute(params, frame) do
    data = %{"co_assignee_ids" => params.co_assignee_ids}

    [%{"op" => "update", "type" => "task", "id" => params.task_id, "data" => data}]
    |> Client.operations()
    |> then(&ToolResult.reply(frame, &1))
  end
end
