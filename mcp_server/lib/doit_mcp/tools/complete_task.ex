defmodule DoitMcp.Tools.CompleteTask do
  @moduledoc """
  Mark one task done or not done. The server applies the same state to every descendant and rolls up ancestor progress; never send separate completion updates for descendants.

  Never loop this tool; batch multiple operations with `apply_operations`. Reply with `index` and `title`, never ids.
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.Tools.ExpectedVersion
  alias DoitMcp.{Client, ToolResult}

  @expected_version_doc ExpectedVersion.description()

  schema do
    field(:task_id, :integer, required: true)
    field(:done, :boolean, required: true)

    field(:expected_version, :integer,
      required: false,
      description: @expected_version_doc
    )
  end

  def execute(params, frame) do
    data = ExpectedVersion.put(%{"done" => params.done}, params)

    [%{"op" => "update", "type" => "task", "id" => params.task_id, "data" => data}]
    |> Client.operations()
    |> then(&ToolResult.reply(frame, &1))
  end
end
