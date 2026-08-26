defmodule DoitMcp.Tools.RemoveMember do
  @moduledoc """
  Remove one member from an Initiative. Only an Initiative admin can use this tool.

  In `apply_operations`, always put the target `initiative_id` and `user_id` inside `data`; never use a top-level `id` or `lid`, because a member has a composite key.
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.{Client, ToolResult}

  schema do
    field(:initiative_id, :integer, required: true)
    field(:user_id, :integer, required: true)
  end

  def execute(params, frame) do
    data =
      params
      |> Map.take([:initiative_id, :user_id])
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    [%{"op" => "remove", "type" => "member", "data" => data}]
    |> Client.operations()
    |> then(&ToolResult.reply(frame, &1))
  end
end
