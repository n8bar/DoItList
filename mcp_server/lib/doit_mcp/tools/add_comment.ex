defmodule DoitMcp.Tools.AddComment do
  @moduledoc """
  Add one comment to a task. `body` accepts `%<task_id>` cross-reference tokens. To comment on an Initiative, always use its `root_task_id` as `task_id`.

  Keep a task's journal comment to one or two concise sentences stating what changed and why; put material detail on the task. Root-thread audits and provenance may be longer.

  When a pass adds comments to multiple tasks, always use one `apply_operations` batch; never loop `add_comment`.
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
