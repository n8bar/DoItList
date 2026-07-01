defmodule DoitMcp.Tools.RemoveMember do
  @moduledoc """
  Remove a member from an Initiative. Admin-only — the API rejects this when
  the caller isn't an admin of the Initiative.

  `member` ops carry their target (`initiative_id` + `user_id`) inside
  `data`, not as a top-level `id`/`lid` — members don't have a single-column
  id the wire protocol addresses directly.
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
