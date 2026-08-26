defmodule DoitMcp.Tools.AddMember do
  @moduledoc """
  Add one member to an Initiative. Only an Initiative admin can use this tool. Always set `role` to `"editor"` or `"viewer"`; never use `"owner"`, because ownership transfer is a separate guarded flow.
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.{Client, ToolResult}

  schema do
    field(:initiative_id, :integer, required: true)
    field(:user_id, :integer, required: true)
    field(:role, :string, required: true)
  end

  def execute(params, frame) do
    data =
      params
      |> Map.take([:initiative_id, :user_id, :role])
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    [%{"op" => "add", "type" => "member", "data" => data}]
    |> Client.operations()
    |> then(&ToolResult.reply(frame, &1))
  end
end
