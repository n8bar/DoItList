defmodule DoitMcp.Tools.AddComment do
  @moduledoc """
  Add a comment to a task — mirrors `add comment` in the Arc 1 op table.

  The Initiative's own thread is its root task's comments: to comment on the
  Initiative itself, pass `task_id` = the Initiative payload's `root_task_id`.

  Commenting on more than a couple of tasks in one pass → use
  `apply_operations` as one batch instead of looping this tool.
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
