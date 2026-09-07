defmodule DoitMcp.Tools.UpdateTask do
  @moduledoc """
  Update one task's title, description, priority, assignee, or manual progress. `title` and `description` accept `%<task_id>` cross-reference tokens. Use `complete_task` for completion and `move_task` for parent or position changes.

  Never loop this tool; batch multiple operations with `apply_operations`.
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.Tools.ExpectedVersion
  alias DoitMcp.{Client, ToolResult}

  @expected_version_doc ExpectedVersion.description()

  schema do
    field(:task_id, :integer, required: true)
    field(:title, :string, required: false)
    field(:description, :string, required: false)
    field(:priority, :string, required: false)
    field(:assignee_id, :integer, required: false)
    field(:manual_progress, :integer, required: false)

    field(:expected_version, :integer,
      required: false,
      description: @expected_version_doc
    )
  end

  def execute(params, frame) do
    data =
      params
      |> Map.take([
        :title,
        :description,
        :priority,
        :assignee_id,
        :manual_progress,
        :expected_version
      ])
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    [%{"op" => "update", "type" => "task", "id" => params.task_id, "data" => data}]
    |> Client.operations()
    |> then(&ToolResult.reply(frame, &1))
  end
end
