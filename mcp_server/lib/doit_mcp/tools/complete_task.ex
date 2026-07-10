defmodule DoitMcp.Tools.CompleteTask do
  @moduledoc """
  Mark a task done or not done. Completion cascades server-side to
  descendants (marked done/undone alongside it) and rolls up to ancestors'
  progress — this tool just sends the flag, the API owns the cascade.

  Completing more than a couple of tasks in one pass → use `apply_operations`
  as one batch instead of looping this tool.
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.{Client, ToolResult}

  schema do
    field(:task_id, :integer, required: true)
    field(:done, :boolean, required: true)
  end

  def execute(params, frame) do
    [
      %{
        "op" => "update",
        "type" => "task",
        "id" => params.task_id,
        "data" => %{"done" => params.done}
      }
    ]
    |> Client.operations()
    |> then(&ToolResult.reply(frame, &1))
  end
end
