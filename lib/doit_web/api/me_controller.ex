defmodule DoItWeb.Api.MeController do
  @moduledoc """
  `GET /api/v1/me` — the minimal protected endpoint that anchors the API
  pipeline (m03.01 worklist 1.3). Returns the acting user (resolved from the
  Bearer token) in the success envelope. The real read endpoints are worklist 2.
  """
  use DoItWeb, :controller

  alias DoItWeb.Api

  action_fallback DoItWeb.Api.FallbackController

  def show(conn, _params) do
    user = conn.assigns.current_user

    json(conn, Api.data(%{
      id: user.id,
      email: user.email,
      username: user.username,
      name: user.name
    }))
  end
end
