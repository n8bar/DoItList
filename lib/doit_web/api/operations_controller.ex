defmodule DoItWeb.Api.OperationsController do
  @moduledoc """
  `POST /api/v1/operations` — the atomic mutation surface (m03.01 worklist 3).

  Takes `{"operations": [<op>, ...]}` and applies the ordered list
  all-or-nothing in one transaction. The engine, the op envelope, the wired op
  set, the per-op authorization matrix, and the success / per-op-error response
  shapes all live in `DoItWeb.Api.Operations` (and the per-op error shape is
  pinned in `DoItWeb.Api`). The apply + idempotency + render flow — shared
  verbatim with the browser client's `POST /app/api/operations` — lives in
  `DoItWeb.Api.OperationsEndpoint`. This controller is the thin bearer-token
  edge over it.
  """
  use DoItWeb, :controller

  alias DoItWeb.Api.OperationsEndpoint

  @doc "Apply an ordered batch of write operations, all or nothing."
  def create(conn, params), do: OperationsEndpoint.create(conn, params, surface: :agent)
end
