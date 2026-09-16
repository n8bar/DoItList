defmodule DoItWeb.Client.AuthPlug do
  @moduledoc """
  Requires a signed-in web session on `/app/api`, rendering JSON (m04.01
  worklist 5).

  `DoItWeb.UserAuth.require_authenticated_user/2` redirects to the login page —
  right for a browser navigation, useless to a `fetch()`. This plug is its JSON
  twin: no session, no redirect, a `401` in the documented single-error shape.

  It reads **only** `conn.assigns.current_user`, which
  `DoItWeb.UserAuth.fetch_current_user/2` resolves from the session cookie. An
  `Authorization` header is never consulted here, so a bearer token alone —
  however valid on `/api/v1` — is a `401` on this surface.
  """

  alias DoItWeb.Client.Api

  def init(opts), do: opts

  def call(conn, _opts) do
    if conn.assigns[:current_user], do: conn, else: Api.unauthorized(conn)
  end
end
