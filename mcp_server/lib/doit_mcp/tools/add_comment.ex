defmodule DoitMcp.Tools.AddComment do
  @moduledoc """
  Add a comment to a task — mirrors `add comment` in the Arc 1 op table.
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.{Client, ToolResult}

  schema do
    field(:task_id, :integer, required: true)
    field(:body, :string, required: true)
  end

  def execute(params, frame) do
    data =
      params
      |> Map.take([:task_id, :body])
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    [%{"op" => "add", "type" => "comment", "data" => data}]
    |> Client.operations()
    |> then(&ToolResult.reply(frame, &1))
  end
end
