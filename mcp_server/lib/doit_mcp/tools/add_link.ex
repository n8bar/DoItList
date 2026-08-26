defmodule DoitMcp.Tools.AddLink do
  @moduledoc """
  Add one directed task-to-task cross-reference link. Always use tasks from the same Initiative; the acting user must have edit access to the source task's Initiative.
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.{Client, ToolResult}

  schema do
    field(:source_task_id, :integer, required: true)
    field(:target_task_id, :integer, required: true)
  end

  def execute(params, frame) do
    data = %{"source_id" => params.source_task_id, "target_id" => params.target_task_id}

    [%{"op" => "add", "type" => "link", "data" => data}]
    |> Client.operations()
    |> then(&ToolResult.reply(frame, &1))
  end
end
