defmodule DoitMcp.Tools.UpdateInitiative do
  @moduledoc """
  Content-only edit of an Initiative's fields (name, description, subtitle,
  progress calc, index style, AI knobs, auto-promote co-assignees, viewer+).
  This tool does NOT touch state (archived/hidden/trashed — see
  `set_initiative_state`) or ownership — those are rejected here or
  handled elsewhere.
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.{Client, ToolResult}

  schema do
    field(:initiative_id, :integer, required: true)
    field(:name, :string, required: false)
    field(:description, :string, required: false)
    field(:subtitle, :string, required: false)
    field(:progress_calc, :string, required: false)
    field(:index_style, :string, required: false)

    field(:ai_knobs, :string,
      required: false,
      description:
        "Per-project agent settings store — plain text the product stores but never interprets"
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
        :progress_calc,
        :index_style,
        :ai_knobs,
        :auto_promote_co_assignees,
        :viewer_plus
      ])
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    [%{"op" => "update", "type" => "initiative", "id" => params.initiative_id, "data" => data}]
    |> Client.operations()
    |> then(&ToolResult.reply(frame, &1))
  end
end
