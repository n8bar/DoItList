defmodule DoItWeb.Client.CsrfPlug do
  @moduledoc """
  CSRF protection for `/app/api` that renders JSON instead of an HTML error
  page (m04.01 worklist 5).

  The check itself is Plug's, unchanged — `Plug.CSRFProtection`, the same one
  `:protect_from_forgery` runs for the browser pipeline, so the token the root
  layout publishes and the token this accepts can't drift. Only the failure
  path differs: the raised `InvalidCSRFTokenError` becomes a `403` with code
  `stale_session` in the single-error JSON shape, telling the client to re-read
  `GET /app/api/session` and retry rather than handing a `fetch()` a page of
  HTML.

  Safe methods (`GET`/`HEAD`/`OPTIONS`) are not validated; running the plug on
  them is what mints and stores the session's token, so `GET /app/api/session`
  can hand one back.
  """

  alias DoItWeb.Client.Api

  def init(opts), do: Plug.CSRFProtection.init(opts)

  def call(conn, opts) do
    Plug.CSRFProtection.call(conn, opts)
  rescue
    Plug.CSRFProtection.InvalidCSRFTokenError -> Api.stale_session(conn)
    Plug.CSRFProtection.InvalidCrossOriginRequestError -> Api.stale_session(conn)
  end
end
