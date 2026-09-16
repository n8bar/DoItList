defmodule DoItWeb.Client.SessionController do
  @moduledoc """
  `GET /app/api/session` — who the browser is signed in as, plus a fresh CSRF
  token (m04.01 worklist 5).

  The client calls this on boot and again after a `stale_session` error: the
  token in the body is the one its writes must send as `x-csrf-token`, so a
  session that outlived the page's `<meta name="csrf-token">` recovers without
  a reload. The user shape is `DoItWeb.Api.Identity.user/1` — the same one
  `GET /api/v1/me` returns.
  """
  use DoItWeb, :controller

  alias DoItWeb.Api
  alias DoItWeb.Api.Identity

  action_fallback DoItWeb.Client.FallbackController

  @doc "The signed-in user and a fresh CSRF token."
  def show(conn, _params) do
    json(
      conn,
      Api.data(%{
        user: Identity.user(conn.assigns.current_user),
        csrf_token: get_csrf_token()
      })
    )
  end
end
