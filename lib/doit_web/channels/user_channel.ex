defmodule DoItWeb.UserChannel do
  @moduledoc """
  One user's own channel (m04.01 item 4.6.2), topic `"user:<id>"`.

  It carries what happens *to you*, wherever you are in the client: today that
  is one event, `"notification"`, whose payload is the same serialised row
  `GET /app/api/notifications` returns (`DoItWeb.Api.NotificationView`), so the
  client prepends what arrives without a second shape to understand.

  Joining is only ever as **yourself**: the socket already knows who it belongs
  to (`DoItWeb.UserSocket` authenticates on the session), and a topic naming
  anybody else is refused. There is no role to consult — a notification belongs
  to exactly one user.

  The channel subscribes to `DoIt.Notifications.user_topic/1`, the same PubSub
  topic the LiveView header listens on, so both clients learn about a
  notification from the one broadcast `DoIt.Notifications.create/3` fires.
  """
  use DoItWeb, :channel

  alias DoIt.Notifications
  alias DoItWeb.Api.NotificationView

  @impl true
  def join("user:" <> id, _params, socket) do
    user = socket.assigns.current_user

    if id == Integer.to_string(user.id) do
      Phoenix.PubSub.subscribe(DoIt.PubSub, Notifications.user_topic(user.id))
      {:ok, %{user_id: user.id}, socket}
    else
      {:error, %{reason: "forbidden"}}
    end
  end

  @impl true
  def handle_info({:notification, notification}, socket) do
    push(socket, "notification", NotificationView.summary(notification))
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}
end
