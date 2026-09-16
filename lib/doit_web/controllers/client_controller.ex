defmodule DoItWeb.ClientController do
  @moduledoc """
  Serves the **bootstrap document** for the browser-owned React client at
  `/app` (m04.01 worklist 2).

  One dead (non-LiveView) document answers `/app` and every path beneath it:
  the client owns routing in the browser, so a deep link is a full-document
  load of the same shell, not a different page. The document carries no
  product-shaped server-rendered markup — only a loading state, a `<noscript>`
  message, and the recovery screens the inline handler swaps in when the
  bundle or the client itself fails (resilient-client spec §2). Anything that
  looks like a Task tree is painted by the client, never by the server.

  ## Identity and CSRF (spec §12)

  The document carries the signed-in user and the CSRF token in a
  `<script type="application/json" id="bootstrap">` block, plus the usual
  `<meta name="csrf-token">`. There is **no bearer token anywhere**: the client
  authenticates to `/app/api` with the session cookie the browser already
  holds, and sends the CSRF token as the `x-csrf-token` header on writes (see
  `DoItWeb.Client.Api`).

  Signed out is not a redirect — the document still renders `200` with
  `user: null` and the client paints its own "Signed out" screen with a link
  to the login page. That keeps the recovery story in one place (the client)
  instead of splitting it between a server redirect and a client state.
  """
  use DoItWeb, :controller

  alias DoItWeb.Api.Errors
  alias DoItWeb.Api.Identity

  @doc """
  Renders the single bootstrap document.

  `GET /app/api/...` that matched nothing in the JSON scope above falls through
  to this catch-all; answer those with the API's own JSON 404 rather than
  handing a `fetch()` a page of HTML.
  """
  def index(conn, %{"path" => ["api" | _]}) do
    Errors.send_error(conn, 404, :not_found, "No such endpoint.")
  end

  def index(conn, _params) do
    user = conn.assigns[:current_user]

    bootstrap = %{
      user: user && Identity.user(user),
      csrf_token: get_csrf_token(),
      path: conn.request_path
    }

    conn
    |> put_root_layout(false)
    |> put_layout(false)
    # The pipeline also accepts JSON (so an unknown /app/api fetch can reach the
    # clause above); the document itself is always HTML.
    |> put_format(:html)
    |> assign(:current_user, user)
    |> assign(:bootstrap_json, Jason.encode!(bootstrap, escape: :html_safe))
    |> render(:index)
  end
end
