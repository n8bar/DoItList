defmodule DoitMcp.Tools.CreateInitiative do
  @moduledoc """
  Create one Initiative, the top-level container that owns a task tree. Creation always uses `leaf_average`; only when the operator explicitly requested another progress calculation, create the Initiative first and then use `update_initiative`.
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.{Client, ToolResult}

  schema do
    field(:name, :string, required: true)
    field(:description, :string, required: false)
    field(:subtitle, :string, required: false)

    field(:index_style, :string,
      required: false,
      description:
        "Task numbering: none (default), outline, numerical, roman, or alphabetical. Always preserve a source's outline, numerical, roman, or alphabetical scheme. If it has none, use numerical for a hierarchy and none for a plain, non-referenced list"
    )

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
