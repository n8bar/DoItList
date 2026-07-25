defmodule DoitMcp.Tools.CreateInitiative do
  @moduledoc """
  Create an Initiative — the top-level container that owns a task tree.

  Creation always lands `leaf_average` (the product's default progress
  calculation); changing the calc happens only via `update_initiative`, where
  a non-default choice is held for the operator's confirm.
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
        "Task-numbering scheme: none (default), outline, numerical, roman, alphabetical. " <>
          "An imported/hierarchical source matches the source's scheme when it has a usable " <>
          "one (outline, numerical, roman, alphabetical); a hierarchy with no usable scheme " <>
          "takes numerical; a plain non-referenced list stays none"
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
