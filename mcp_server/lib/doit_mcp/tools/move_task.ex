defmodule DoitMcp.Tools.MoveTask do
  @moduledoc """
  Move one task to a new parent and/or sibling position. Provide at least one of `parent_id`, `position`, or `reorder`; an empty move is rejected. Omitting `parent_id` keeps the current parent. Set `reorder: true` only for an explicit sibling reorder; it switches the destination to manual sorting. Omit it to append.

  Never loop this tool; batch multiple operations with `apply_operations`.
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
