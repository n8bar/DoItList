defmodule DoitMcp.Tools.CompleteTask do
  @moduledoc """
  Mark one task done or not done. The server applies the same state to every descendant and rolls up ancestor progress; never send separate completion updates for descendants.

  Never loop this tool; batch multiple operations with `apply_operations`.
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
