defmodule DoitMcp.Tools.EditComment do
  @moduledoc """
  Edit the body of an existing comment. Author-only — the API rejects this
  when the caller isn't the comment's author.
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.{Client, ToolResult}

  schema do
    field(:comment_id, :integer, required: true)
    field(:body, :string, required: true)
  end

  def execute(params, frame) do
    data =
      params
      |> Map.take([:body])
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    [%{"op" => "update", "type" => "comment", "id" => params.comment_id, "data" => data}]
    |> Client.operations()
    |> then(&ToolResult.reply(frame, &1))
  end
end
