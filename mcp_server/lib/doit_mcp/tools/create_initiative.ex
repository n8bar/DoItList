defmodule DoitMcp.Tools.CreateInitiative do
  @moduledoc """
  Create an Initiative — the top-level container that owns a task tree.
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.{Client, ToolResult}

  schema do
    field(:name, :string, required: true)
    field(:description, :string, required: false)
    field(:subtitle, :string, required: false)
    field(:progress_calc, :string, required: false)
    field(:index_style, :string, required: false)
    field(:auto_promote_co_assignees, :boolean, required: false)
    field(:viewer_plus, :boolean, required: false)
  end

  def execute(params, frame) do
    data =
      params
      |> Map.take([
        :name,
        :description,
        :subtitle,
        :progress_calc,
        :index_style,
        :auto_promote_co_assignees,
        :viewer_plus
      ])
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    [%{"op" => "add", "type" => "initiative", "data" => data}]
    |> Client.operations()
    |> then(&ToolResult.reply(frame, &1))
  end
end
