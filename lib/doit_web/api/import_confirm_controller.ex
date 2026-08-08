defmodule DoItWeb.Api.ImportConfirmController do
  @moduledoc """
  The import-confirm endpoints (m03.04 item 30.1) — the MCP adapter's side of
  the server-recorded readback confirm:

    * `POST /api/v1/import_confirms` — `create`, park a pending confirm:
      `{"payload_hash": ..., "readback": ..., "initiative_id": <optional>}`.
      Initiative-homed parks are authz-checked (`:edit` — the confirm guards a
      write); no `initiative_id` homes the confirm on the account (a bootstrap
      batch). Idempotent: an existing PENDING row for the same home + hash is
      returned as-is; a decided row does not block a new park (a re-park after
      hold/correct opens a fresh pending row).
    * `GET /api/v1/import_confirms/:payload_hash` — `show`, the newest row for
      the acting user + hash: status, corrections, url. 404 when none.

  Deciding is NOT here by design: the agent holds the operator's bearer
  token, so a decision-write on this surface would let it approve its own
  confirm. Decisions happen in the app's UI only (`DoIt.ImportConfirms.decide/4`).
  Responses carry a server-composed `url` — the operator-facing handle to the
  page the confirm card renders on (`DoItWeb.Api.Serializer.import_confirm/1`).
  """
  use DoItWeb, :controller

  alias DoIt.ImportConfirms
  alias DoItWeb.Api
  alias DoItWeb.Api.{Authz, Errors, Serializer}

  action_fallback DoItWeb.Api.FallbackController

  def create(conn, %{"payload_hash" => hash, "readback" => readback} = params)
      when is_binary(hash) and is_binary(readback) do
    user = conn.assigns.current_user

    with {:ok, initiative} <- fetch_home(user, params["initiative_id"]),
         {:ok, confirm} <- ImportConfirms.park(user, initiative && initiative.id, params) do
      json(conn, Api.data(Serializer.import_confirm(confirm)))
    end
  end

  def create(conn, _params) do
    Errors.send_error(
      conn,
      422,
      :unprocessable_entity,
      "Request body must carry string \"payload_hash\" and \"readback\" " <>
        "(plus an optional \"initiative_id\" homing the confirm on an Initiative)."
    )
  end

  def show(conn, %{"payload_hash" => hash}) do
    user = conn.assigns.current_user

    case ImportConfirms.latest_by_hash(user, hash) do
      nil -> {:error, :not_found}
      confirm -> json(conn, Api.data(Serializer.import_confirm(confirm)))
    end
  end

  defp fetch_home(_user, nil), do: {:ok, nil}
  defp fetch_home(user, initiative_id), do: Authz.fetch_initiative(user, initiative_id, :edit)
end
