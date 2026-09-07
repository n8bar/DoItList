defmodule DoitMcp.Tools.DeleteTask do
  @moduledoc """
  Soft-delete one task and its entire subtree; never delete included descendants separately. Recovery is only through the app's Undo, while the deletion remains in the Initiative's undo history.

  Never loop this tool; batch multiple operations with `apply_operations`.
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
