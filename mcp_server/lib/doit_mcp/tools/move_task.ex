defmodule DoitMcp.Tools.MoveTask do
  @moduledoc """
  Move one task to a new parent and/or sibling position — reorder, reparent, promote, and demote are all this tool. Provide at least one of `parent_id`, `position`, or `reorder`; an empty move is rejected. Omitting `parent_id` keeps the current parent. Set `reorder: true` only for an explicit sibling reorder; it switches the destination to manual sorting. Omit it to append.

  Never loop this tool; batch multiple operations with `apply_operations`.
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.Tools.ExpectedVersion
  alias DoitMcp.{Client, ToolResult}

  @expected_version_doc ExpectedVersion.description()

  schema do
    field(:task_id, :integer, required: true)
    field(:parent_id, :integer, required: false)
    field(:position, :integer, required: false)
    field(:reorder, :boolean, required: false)

    field(:expected_version, :integer,
      required: false,
      description: @expected_version_doc
    )
  end

  def execute(params, frame) do
    data =
      params
      |> Map.take([:parent_id, :position, :reorder, :expected_version])
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    [%{"op" => "update", "type" => "task", "id" => params.task_id, "data" => data}]
    |> Client.operations()
    |> then(&ToolResult.reply(frame, &1))
  end
end
