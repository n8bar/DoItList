defmodule DoitMcp.Tools.SetInitiativeState do
  @moduledoc """
  Change one Initiative's lifecycle state. Always set `state` to exactly one of `archived`, `unarchived`, `hidden`, `unhidden`, `trashed`, or `restored`; every other value is rejected.
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.{Client, ToolResult}

  schema do
    field(:initiative_id, :integer, required: true)
    field(:state, :string, required: true)
  end

  def execute(params, frame) do
    data = %{"state" => params.state}

    [%{"op" => "update", "type" => "initiative", "id" => params.initiative_id, "data" => data}]
    |> Client.operations()
    |> then(&ToolResult.reply(frame, &1))
  end
end
