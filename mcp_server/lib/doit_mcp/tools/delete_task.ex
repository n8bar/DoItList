defmodule DoitMcp.Tools.DeleteTask do
  @moduledoc """
  Soft-delete (Trash) a task and its subtree. Reversible — this does not
  permanently destroy data, it moves the task and its descendants to Trash.
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.{Client, ToolResult}

  schema do
    field(:task_id, :integer, required: true)
  end

  def execute(params, frame) do
    [%{"op" => "remove", "type" => "task", "id" => params.task_id}]
    |> Client.operations()
    |> then(&ToolResult.reply(frame, &1))
  end
end
