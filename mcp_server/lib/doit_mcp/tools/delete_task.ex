defmodule DoitMcp.Tools.DeleteTask do
  @moduledoc """
  Soft-delete a task and its subtree. This does not permanently destroy
  data; it is reversible — but only through the app's Undo, and only while
  the deletion stays within the Initiative's undo history.
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
