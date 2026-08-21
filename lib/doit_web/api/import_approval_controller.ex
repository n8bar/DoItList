defmodule DoItWeb.Api.ImportApprovalController do
  @moduledoc """
  The import-approval endpoints (m03.04 2.8.8) — the MCP adapter's side of
  the operator's one-click open-only import override:

    * `POST /api/v1/import_approvals` — `create`, park a refused open-only
      bootstrap: `{"payload_hash": ..., "task_count": ..., "initiative_name":
      ...}`. Account-homed (a bootstrap batch's Initiative doesn't exist
      yet). Idempotent per `DoIt.ImportApprovals.park/2`: an unexpired
      pending row or a decided row for the hash is returned as-is; a
      dismissed hash stays dismissed (the latch) — no fresh park.
    * `GET /api/v1/import_approvals/:payload_hash` — `show`, the newest row
      for the acting user + hash: status, counts, url. 404 when none.

  Deciding is NOT here by design: the agent holds the operator's bearer
  token, so a decision-write on this surface would let it approve its own
  import. Decisions happen in the app's UI only (`DoIt.ImportApprovals.decide/3`).
  Responses carry a server-composed `url` — the operator-facing handle to
  the account page the card renders on.

  The account-level off-switch (m03.04 2.8.9): an account with
  `skip_import_approvals` set answers `status: "skipped"` from BOTH endpoints
  — regardless of any standing row — before touching storage: the ceremony is
  dormant for this operator, so nothing parks and no standing decision gates
  a batch. This consult is the field's ONLY read exposure on the API; the
  flag itself is writable through the app's session-authed UI alone.
  """
  use DoItWeb, :controller

  alias DoIt.ImportApprovals
  alias DoItWeb.Api
  alias DoItWeb.Api.{Errors, Serializer}

  action_fallback DoItWeb.Api.FallbackController

  def create(
        conn,
        %{"payload_hash" => hash, "task_count" => count, "initiative_name" => name} = params
      )
      when is_binary(hash) and is_integer(count) and is_binary(name) do
    user = conn.assigns.current_user

    if user.skip_import_approvals do
      json(conn, Api.data(skipped(hash)))
    else
      with {:ok, approval} <- ImportApprovals.park(user, params) do
        json(conn, Api.data(Serializer.import_approval(approval)))
      end
    end
  end

  def create(conn, _params) do
    Errors.send_error(
      conn,
      422,
      :unprocessable_entity,
      "Request body must carry string \"payload_hash\", integer \"task_count\", " <>
        "and string \"initiative_name\"."
    )
  end

  def show(conn, %{"payload_hash" => hash}) do
    user = conn.assigns.current_user

    cond do
      user.skip_import_approvals ->
        json(conn, Api.data(skipped(hash)))

      approval = ImportApprovals.latest_by_hash(user, hash) ->
        json(conn, Api.data(Serializer.import_approval(approval)))

      true ->
        {:error, :not_found}
    end
  end

  # The off-switch answer (m03.04 2.8.9) — not a row, so not the serializer's
  # shape: just the hash echoed back and the fact the ceremony is off.
  defp skipped(hash), do: %{payload_hash: hash, status: "skipped"}
end
