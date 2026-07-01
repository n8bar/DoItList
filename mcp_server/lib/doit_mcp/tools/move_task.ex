defmodule DoitMcp.Tools.MoveTask do
  @moduledoc """
  Reparent and/or reorder a task among siblings. Omit `parent_id` to keep
  the current parent. `reorder: true` marks an explicit sibling reorder,
  pinning the destination to manual sort; omit it for a plain reparent
  that just appends. At least one of `parent_id`, `position`, `reorder`
  must be given — the underlying API rejects an update with zero fields.
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
