defmodule DoitMcp.Tools.DeleteComment do
  @moduledoc """
  Delete one comment. The server soft-deletes it and leaves a tombstone. Only its author can delete it; every other caller is rejected.
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.{Client, ToolResult}

  schema do
    field(:comment_id, :integer, required: true)
  end

  def execute(params, frame) do
    [%{"op" => "remove", "type" => "comment", "id" => params.comment_id}]
    |> Client.operations()
    |> then(&ToolResult.reply(frame, &1))
  end
end
