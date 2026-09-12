defmodule DoItWeb.Api.ImportController do
  @moduledoc """
  `POST /api/v1/imports` — text import (m03.04 2.3, 2.4).

  Takes a source document, a target, and a `preview` flag; returns the parsed
  outline with its counts and detected index style, and — outside preview mode —
  the Task tree it just built plus the Initiative's URL. The request/response
  contract, the parse → chunk → apply pipeline, the source comment, and the
  per-source-text idempotency all live in `DoItWeb.Api.Imports`.

  This controller is the thin HTTP edge: it pulls the acting user and the
  access token id (both resolved by `DoItWeb.Api.AuthPlug`; stored previews
  are keyed by token) off the conn, delegates, and renders whichever
  `{status, body}` the service returned.
  """
  use DoItWeb, :controller

  alias DoItWeb.Api.Imports

  def create(conn, params) do
    {_, status, body} = Imports.run(conn.assigns.current_user, conn.assigns.api_token_id, params)
    conn |> put_status(status) |> json(body)
  end
end
