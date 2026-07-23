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
    * Batch over the `@max_batch_size` cap → `422` single-error naming the count
      and the limit (rejected before any DB work).
    * Malformed body (no non-empty `operations` array) → `422` single-error.

  ## Idempotent retries (m03.03 worklist 2.2)

  A client may send an `Idempotency-Key` request header (Stripe's convention).
  On the first request for a `(user, key)` the batch runs normally and, when it
  **commits**, its response is stored beside a hash of the decoded payload; a
  later request carrying the **same** key **and the same payload** **replays**
  that stored response verbatim instead of re-applying the batch — so a retry
  after a client-side timeout can't double-apply. The key binds to its exact
  payload (m03.04 fix 20): a same-key request whose payload differs gets a `422`
  naming the key conflict — a revised batch takes a new key. Only a commit is
  stored: a rolled-back batch and the pre-execution rejections (batch-too-large,
  malformed body) commit nothing and store nothing, so an honest retry of them
  re-executes. Same-key requests **in flight together** serialize on a
  per-`(user, key)` advisory lock (m03.04 2.19), so a racing retry waits, then
  replays — it can never double-apply. With no header, behavior is exactly as
  above and no lock is taken. The key itself is enforced server-side here; the
  MCP tool merely forwards it.
  """
  use DoItWeb, :controller

  alias DoIt.Api.Idempotency
  alias DoItWeb.Api.{Errors, Operations}

  def create(conn, %{"operations" => operations}) do
    user = conn.assigns.current_user

    case idempotency_key(conn) do
      nil ->
        render_outcome(conn, Operations.apply_batch(user, operations))

      key ->
        payload_hash = Idempotency.payload_hash(operations)

        # The whole fetch -> apply -> store window holds the (user, key)
        # advisory lock (m03.04 2.19): a same-key request racing this one
        # blocks here, then fetches the winner's stored response and replays.
        Idempotency.with_key_lock(user, key, fn ->
          case Idempotency.fetch(user, key, payload_hash) do
            {:replay, {status, body}} ->
              # Replay the first attempt's stored response — no re-execution.
              conn |> put_status(status) |> json(body)

            :payload_conflict ->
              key_conflict(conn)

            nil ->
              outcome = Operations.apply_batch(user, operations)
              store_if_committed(user, key, payload_hash, outcome)
              render_outcome(conn, outcome)
          end
        end)
    end
  end

  def create(conn, _params), do: invalid_request(conn)

  # The `Idempotency-Key` request header (Plug lowercases header names), or nil
  # when absent/blank.
  defp idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [key | _] when is_binary(key) and key != "" -> key
      _ -> nil
    end
  end

  # Persist ONLY a commit, captured through the SAME {status, body} the
  # response uses, so a replay is byte-identical to what was sent — bound to
  # the payload hash the key now carries. A rollback or a pre-execution
  # rejection commits nothing and stores nothing (m03.04 fix 20): an honest
  # retry of a failed batch re-executes instead of replaying the failure.
  defp store_if_committed(user, key, payload_hash, {:ok, _results} = outcome) do
    {status, body} = execution_response(outcome)
    Idempotency.store(user, key, payload_hash, status, body)
  end

  defp store_if_committed(_user, _key, _payload_hash, _outcome), do: :ok

  # The single {status, body} shape used for BOTH the HTTP response and the
  # stored idempotency record of an execution outcome.
  defp execution_response({:ok, results}), do: {200, %{results: results}}

  defp execution_response({:error, status, results, top_error}),
    do: {status, %{error: top_error, results: results}}

  # Render any apply_batch/2 outcome. The two pre-execution rejections keep their
  # single-error shapes; every execution outcome goes through execution_response/1
  # so the sent body matches the one store_if_execution/3 persists.
  defp render_outcome(conn, {:error, :batch_too_large, message}),
    do: Errors.send_error(conn, 422, :unprocessable_entity, message)

  defp render_outcome(conn, {:error, :invalid_request}), do: invalid_request(conn)

  defp render_outcome(conn, outcome) do
    {status, body} = execution_response(outcome)
    conn |> put_status(status) |> json(body)
  end

  defp invalid_request(conn) do
    Errors.send_error(
      conn,
      422,
      :unprocessable_entity,
      "Request body must be a JSON object {\"operations\": [ ... ]} with a non-empty array of operations."
    )
  end

  defp key_conflict(conn) do
    Errors.send_error(
      conn,
      422,
      :unprocessable_entity,
      "Idempotency-Key conflict: this key was first used with a different payload. " <>
        "A revised batch takes a new Idempotency-Key."
    )
  end
end
