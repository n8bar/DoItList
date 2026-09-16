defmodule DoItWeb.Client.SessionController do
  @moduledoc """
  `GET /app/api/session` — who the browser is signed in as, plus a fresh CSRF
  token (m04.01 worklist 5).

  The client calls this on boot and again after a `stale_session` error: the
  token in the body is the one its writes must send as `x-csrf-token`, so a
  session that outlived the page's `<meta name="csrf-token">` recovers without
  a reload. The user shape is `DoItWeb.Api.Identity.user/1` — the same one
  `GET /api/v1/me` returns.

  It also carries `preferences` — the four "Task attributes shown on rows"
  choices from the account's Display elements (m02.04 §2.4). The client draws
  its own task rows (m04.02 worklist 2), so it needs the same four flags the
  LiveView's row rendering honors, and it needs them at boot rather than one
  read per row. Session-only: `/api/v1` has no business with a browser's
  display choices.
  """
  use DoItWeb, :controller

  alias DoIt.Accounts
  alias DoItWeb.Api
  alias DoItWeb.Api.Identity

  action_fallback DoItWeb.Client.FallbackController

  @doc "The signed-in user, their row preferences, and a fresh CSRF token."
  def show(conn, _params) do
    user = conn.assigns.current_user
    prefs = Accounts.get_preferences(user)

    json(
      conn,
      Api.data(%{
        user: Identity.user(user),
        preferences: %{
          show_task_priority: prefs.show_task_priority,
          show_task_assignee: prefs.show_task_assignee,
          show_task_progress: prefs.show_task_progress,
          show_task_count: prefs.show_task_count
        },
        csrf_token: get_csrf_token()
      })
    )
  end
end
