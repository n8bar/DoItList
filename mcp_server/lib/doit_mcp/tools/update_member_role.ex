defmodule DoitMcp.Tools.UpdateMemberRole do
  @moduledoc """
  Change one Initiative member's role. Only an Initiative admin can use this tool. Always set `role` to `"editor"` or `"viewer"`; never use `"owner"`, because ownership transfer is a separate guarded flow.

  In `apply_operations`, always put the target `initiative_id` and `user_id` inside `data`; never use a top-level `id` or `lid`, because a member has a composite key.
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

    [%{"op" => "update", "type" => "member", "data" => data}]
    |> Client.operations()
    |> then(&ToolResult.reply(frame, &1))
  end
end
