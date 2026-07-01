defmodule DoitMcp.Tools.AddLink do
  @moduledoc """
  Add a task-to-task cross-reference link. Same-Initiative only — the acting
  user needs edit access on the source task's Initiative.
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.{Client, ToolResult}

  schema do
    field(:source_task_id, :integer, required: true)
    field(:target_task_id, :integer, required: true)
  end

  def execute(params, frame) do
    data = %{"source_id" => params.source_task_id, "target_id" => params.target_task_id}

    [%{"op" => "add", "type" => "link", "data" => data}]
    |> Client.operations()
    |> then(&ToolResult.reply(frame, &1))
  end
end
