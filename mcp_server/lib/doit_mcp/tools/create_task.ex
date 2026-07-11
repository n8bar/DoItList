defmodule DoitMcp.Tools.CreateTask do
  @moduledoc """
  Create a task. Give `parent_id` to nest under an existing task, or
  `initiative_id` alone to create it top-level (parented to that Initiative's
  root task) — mirrors `add task` in the Arc 1 op table. `title` and
  `description` accept `%<task_id>` cross-reference tokens.
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
        :position
      ])
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    [%{"op" => "add", "type" => "task", "data" => data}]
    |> Client.operations()
    |> then(&ToolResult.reply(frame, &1))
  end
end
