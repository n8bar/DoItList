defmodule DoitMcp.Tools.SetTaskCoAssignees do
  @moduledoc """
  Replace one task's complete co-assignee list. Always provide the full desired ordered list; never provide only the IDs that changed. The server derives additions, removals, and reordering.
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
