defmodule DoitMcp.Tools.MarkNotificationRead do
  @moduledoc """
  Mark one notification or all of the caller's notifications read. Always provide exactly one of `notification_id` for one notification or `all: true` for every notification.
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.{Client, ToolResult}

  schema do
    field(:notification_id, :integer, required: false)
    field(:all, :boolean, required: false)
  end

  def execute(%{all: true}, frame) do
    [%{"op" => "update", "type" => "notification", "data" => %{"all" => true}}]
    |> Client.operations()
    |> then(&ToolResult.reply(frame, &1))
  end

  def execute(%{notification_id: notification_id}, frame) when not is_nil(notification_id) do
    [
      %{
        "op" => "update",
        "type" => "notification",
        "id" => notification_id,
        "data" => %{"read" => true}
      }
    ]
    |> Client.operations()
    |> then(&ToolResult.reply(frame, &1))
  end

  def execute(_params, frame) do
    ToolResult.reply(frame, {:error, %{reason: "must supply notification_id or all: true"}})
  end
end
