defmodule DoItWeb.Client.NotificationController do
  @moduledoc """
  The browser client's notification read (m04.01 item 4.6.1):

    * `GET /app/api/notifications` — `{"recent": [...], "unread": n}`.

  One call into `DoIt.Notifications` — the same `list_recent/2` and
  `unread_count/1` the LiveView header derives its bell from — serialised by
  `DoItWeb.Api.NotificationView`, so the line of text and the link are computed
  once, on the server, for both clients.

  Notifications are user-scoped, so authorization is ownership: the queries take
  the signed-in user and no parameter can widen them. There is no write here —
  marking read is `POST /app/api/operations` (`update notification`), the same
  path the LiveView and the agent API use.
  """
  use DoItWeb, :controller

  alias DoIt.Notifications
  alias DoItWeb.Api
  alias DoItWeb.Api.NotificationView

  action_fallback DoItWeb.Client.FallbackController

  @doc "The signed-in user's recent notifications and their unread count."
  def index(conn, _params) do
    user = conn.assigns.current_user

    json(
      conn,
      Api.data(%{
        recent: Enum.map(Notifications.list_recent(user), &NotificationView.summary/1),
        unread: Notifications.unread_count(user)
      })
    )
  end
end
