defmodule DoitMcp.Tools.AddComment do
  @moduledoc """
  Add a comment to a task — mirrors `add comment` in the Arc 1 op table.
  The `body` accepts `%<task_id>` cross-reference tokens.

  The Initiative's own thread is its root task's comments: to comment on the
  Initiative itself, pass `task_id` = the Initiative payload's `root_task_id`.

  A journal comment on a task is one or two tight sentences — what changed
  and why; detail that matters lives on the task, not in the comment. The
  root thread is the exception: audits and provenance live there and may
  run long.

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
