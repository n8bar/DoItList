defmodule DoitMcp.Tools.RemoveLink do
  @moduledoc """
  Remove a task-to-task cross-reference link, identified by the
  (source, target) pair.
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.{Client, ToolResult}

  schema do
    field(:source_task_id, :integer, required: true)
    field(:target_task_id, :integer, required: true)
  end

  def execute(params, frame) do
    data = %{"source_id" => params.source_task_id, "target_id" => params.target_task_id}

    [%{"op" => "remove", "type" => "link", "data" => data}]
    |> Client.operations()
    |> then(&ToolResult.reply(frame, &1))
  end
end
