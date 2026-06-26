defmodule DoItWeb.Api.Errors do
  @moduledoc """
  The single JSON error-rendering path for `/api/v1` (m03.01 worklist 1.6).

  Both the pipeline plugs (`AuthPlug`, `RateLimitPlug`) and the
  `FallbackController` render through `send_error/5`, so every error — 401, 403,
  404, 422, 429 — comes out in the documented single-error shape (see
  `DoItWeb.Api`).
  """

  import Plug.Conn

  alias DoItWeb.Api

  @doc """
  Render the single-error body at `status` with `code`/`message`, halt the conn.

  `opts[:headers]` is a list of `{name, value}` response headers to add first
  (e.g. `Retry-After` on a 429). Halting is a no-op for the terminal
  `FallbackController` but required for the pipeline plugs.
  """
  def send_error(conn, status, code, message, opts \\ []) do
    opts
    |> Keyword.get(:headers, [])
    |> Enum.reduce(conn, fn {name, value}, acc -> put_resp_header(acc, name, value) end)
    |> put_status(status)
    |> Phoenix.Controller.json(Api.error_body(status, to_string(code), message))
    |> halt()
  end
end
