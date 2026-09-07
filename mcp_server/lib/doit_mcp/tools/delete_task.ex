defmodule DoitMcp.Tools.DeleteTask do
  @moduledoc """
  Soft-delete one task and its entire subtree; never delete included descendants separately. Recovery is only through the app's Undo, while the deletion remains in the Initiative's undo history.

  Never loop this tool; batch multiple operations with `apply_operations`.
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.Tools.ExpectedVersion
  alias DoitMcp.{Client, ToolResult}

  @expected_version_doc ExpectedVersion.description()

  schema do
    field(:task_id, :integer, required: true)

    field(:expected_version, :integer,
      required: false,
      description: @expected_version_doc
    )
  end

  def execute(params, frame) do
    op = %{"op" => "remove", "type" => "task", "id" => params.task_id}

    # `remove` carries no payload of its own; `data` appears only to guard the
    # delete with a version.
    op =
      case ExpectedVersion.put(%{}, params) do
        data when map_size(data) == 0 -> op
        data -> Map.put(op, "data", data)
      end

    [op]
    |> Client.operations()
    |> then(&ToolResult.reply(frame, &1))
  end
end
