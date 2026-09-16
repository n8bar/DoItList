defmodule DoItWeb.Client.OperationsController do
  @moduledoc """
  `POST /app/api/operations` — the browser client's writes (m04.01 worklist 5).

  The same atomic batch as `POST /api/v1/operations`, down to the per-op result
  shape and the `Idempotency-Key` replay: both actions are one call into
  `DoItWeb.Api.OperationsEndpoint`. The only difference is the surface flag,
  which skips the agent-access gate (see `DoItWeb.Api.Operations`); role
  authorization, validation, versioning, and broadcasts are unchanged.
  """
  use DoItWeb, :controller

  alias DoItWeb.Api.OperationsEndpoint

  @doc "Apply an ordered batch of write operations, all or nothing."
  def create(conn, params), do: OperationsEndpoint.create(conn, params, surface: :browser)
end
