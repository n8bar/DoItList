defmodule DoItWeb.Api.OperationsController do
  @moduledoc """
  `POST /api/v1/operations` — the atomic mutation surface (m03.01 worklist 3).

  Takes `{"operations": [<op>, ...]}` and applies the ordered list
  all-or-nothing in one transaction. The engine, the op envelope, the wired op
  set, the per-op authorization matrix, and the success / per-op-error response
  shapes all live in `DoItWeb.Api.Operations` (and the per-op error shape is
  pinned in `DoItWeb.Api`). This controller is the thin HTTP edge: it pulls the
  acting user (resolved by `DoItWeb.Api.AuthPlug`) off the conn, delegates, and
  renders.

    * Batch committed → `200` with `{"results": [...]}`.
    * Batch rolled back → `403` (the offending op failed authorization) or `422`,
      with the top-level `error` plus the per-op `results` (offending op flagged
      `error`, the rest `not_applied`).
    * Malformed body (no non-empty `operations` array) → `422` single-error.
  """
  use DoItWeb, :controller

  alias DoItWeb.Api.{Errors, Operations}

  def create(conn, %{"operations" => operations}) do
    case Operations.apply_batch(conn.assigns.current_user, operations) do
      {:ok, results} ->
        json(conn, %{results: results})

      {:error, status, results, top_error} ->
        conn
        |> put_status(status)
        |> json(%{error: top_error, results: results})

      {:error, :invalid_request} ->
        invalid_request(conn)
    end
  end

  def create(conn, _params), do: invalid_request(conn)

  defp invalid_request(conn) do
    Errors.send_error(
      conn,
      422,
      :unprocessable_entity,
      "Request body must be a JSON object {\"operations\": [ ... ]} with a non-empty array of operations."
    )
  end
end
