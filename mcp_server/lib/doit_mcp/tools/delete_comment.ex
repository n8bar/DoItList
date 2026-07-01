defmodule DoitMcp.Tools.DeleteComment do
  @moduledoc """
  Delete a comment. Author-only — the API rejects this when the caller isn't
  the comment's author. This is a soft-delete/tombstone, not a hard removal.
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
