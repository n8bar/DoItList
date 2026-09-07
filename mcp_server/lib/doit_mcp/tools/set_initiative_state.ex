defmodule DoitMcp.Tools.SetInitiativeState do
  @moduledoc """
  Change one Initiative's lifecycle state. `state` is exactly one of `archived`, `unarchived`, `hidden`, `unhidden`, `trashed`, or `restored`; every other value is rejected.
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.Tools.ExpectedVersion
  alias DoitMcp.{Client, ToolResult}

  @expected_version_doc ExpectedVersion.description()

  schema do
    field(:initiative_id, :integer, required: true)
    field(:state, :string, required: true)

    field(:expected_version, :integer,
      required: false,
      description: @expected_version_doc
    )
  end

  def execute(params, frame) do
    data = ExpectedVersion.put(%{"state" => params.state}, params)

    [%{"op" => "update", "type" => "initiative", "id" => params.initiative_id, "data" => data}]
    |> Client.operations()
    |> then(&ToolResult.reply(frame, &1))
  end
end
