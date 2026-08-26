defmodule DoitMcp.Tools.EditComment do
  @moduledoc """
  Edit one existing comment's body. Only its author can edit it; every other caller is rejected.
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
