defmodule DoitMcp.Tools.CreateTask do
  @moduledoc """
  Create one task. Use `parent_id` to nest it under an existing task, or use `initiative_id` without `parent_id` to create it at the Initiative's top level. `title` and `description` accept `%<task_id>` cross-reference tokens.

  When a plan requires multiple task creations, always use `apply_operations`; never loop `create_task`.
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.{Client, ToolResult}

  schema do
    field(:initiative_id, :integer, required: false)
    field(:parent_id, :integer, required: false)
    field(:title, :string, required: true)
    field(:description, :string, required: false)
    field(:priority, :string, required: false)
    field(:assignee_id, :integer, required: false)
    field(:manual_progress, :integer, required: false)
    field(:position, :integer, required: false)
    field(:done, :boolean, required: false)
  end

  def execute(params, frame) do
    data =
      params
      |> Map.take([
        :initiative_id,
        :parent_id,
        :title,
        :description,
        :priority,
        :assignee_id,
        :manual_progress,
        :position,
        :done
      ])
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    [%{"op" => "add", "type" => "task", "data" => data}]
    |> Client.operations()
    |> then(&ToolResult.reply(frame, &1))
  end
end
