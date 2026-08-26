defmodule DoitMcp.Tools.MoveTask do
  @moduledoc """
  Move one task to a new parent and/or sibling position. Always provide at least one of `parent_id`, `position`, or `reorder`; an empty move is rejected. Omit `parent_id` to keep the current parent. Set `reorder: true` only for an explicit sibling reorder, which switches the destination to manual sorting; omit it when reparenting should append the task.

  When a pass moves multiple tasks, always use one `apply_operations` batch; never loop `move_task`.
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.{Client, ToolResult}

  schema do
    field(:task_id, :integer, required: true)
    field(:parent_id, :integer, required: false)
    field(:position, :integer, required: false)
    field(:reorder, :boolean, required: false)
  end

  def execute(params, frame) do
    data =
      params
      |> Map.take([:parent_id, :position, :reorder])
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    [%{"op" => "update", "type" => "task", "id" => params.task_id, "data" => data}]
    |> Client.operations()
    |> then(&ToolResult.reply(frame, &1))
  end
end
