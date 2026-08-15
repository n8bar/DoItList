defmodule DoitMcp.TokenRecovery.Http do
  @moduledoc """
  Revoked-token recovery without config surgery (m03.04 2.12 + 23.3).

  A dead token still connects — the MCP handshake makes no API call — and
  then 401s every tool call; before this ladder, recovery meant hand-editing
  MCP client config. The whole policy is here, keyed to the session
  (`DoitMcp.TokenRecovery.Sessions`):

    * `credential/0` — the session's in-memory override when a recovery
      installed one, else the bearer header this request arrived with
      (`DoitMcp.SessionToken`); never a VM-wide token.
    * `recover/0` — a session's FIRST 401 raises the same paste-a-fresh-token
      form, riding that session's own server→client stream. The accepted
      token is held in memory KEYED TO THAT SESSION only, overriding its
      header token for the rest of the session — NEVER written to the
      refresh file or anywhere global, never visible to another session.
      A session with no open stream skips the form — straight to guidance.
      Declined, unusable, or rejected-again latches that session failed; a
      no-answer timeout does not latch. While an accepted token's verify
      retry is in flight, a concurrent 401 on the SAME session joins that
      recovery instead of raising a second form (the per-session
      verify-in-flight guard, m03.04 2.13); sessions with valid tokens
      proceed untouched throughout.

  The operator's lasting fix is the Authorization header in this server's
  entry in the MCP client configuration — the one place a session's
  credential comes from.
  """

  alias DoitMcp.{Elicitation, RequestSession, SessionToken}
  alias DoitMcp.TokenRecovery.Sessions

  # A generous paste window — a human has to go mint a token in the web app.
  # Same as the import gate's readback confirm.
  @elicit_timeout to_timeout(minute: 5)

  # Tokens are url-base64-ish; a paste outside this set is never a token —
  # reject it before it burns the one retry.
  @token_format ~r|\A[A-Za-z0-9._+/=-]+\z|

  @token_schema %{
    "type" => "object",
    "properties" => %{
      "token" => %{
        "type" => "string",
        "description" =>
          "A fresh DoItList API token — replaces the rejected one for this session only"
      }
    },
    "required" => ["token"]
  }

  @doc """
  This request's API credential: the session's override if a recovery
  installed one, else the request's bearer header, else `:absent`.
  """
  @spec credential() :: {:ok, String.t()} | :absent
  def credential do
    with session when is_pid(session) <- RequestSession.pid(),
         {:ok, token} <- Sessions.override(session) do
      {:ok, token}
    else
      _ -> SessionToken.fetch()
    end
  end

  @doc """
  The 401 policy — see the moduledoc ladder. Returns `{:ok, fresh_token}`
  when the operator supplied a usable replacement (already installed for
  this session; the caller retries once with it), or `{:error, message}`
  with the actionable message to surface instead of the bare 401 line.
  """
  @spec recover() :: {:ok, String.t()} | {:error, String.t()}
  def recover do
    case RequestSession.pid() do
      nil -> {:error, manual_fix_message()}
      session -> recover(session)
    end
  end

  defp recover(session) do
    cond do
      Sessions.failed?(session) ->
        {:error,
         "A replacement token was already declined or rejected this session — " <>
           "not asking again. " <> manual_fix_message()}

      Sessions.verifying?(session) ->
        # A fresh token was accepted moments ago on THIS session and its
        # verify retry is still in flight — join that recovery: retry with
        # the installed override instead of raising a second form (m03.04
        # 2.20, per session). A dead override latches via the joiner's retry
        # exactly like the verifier's would.
        case Sessions.override(session) do
          {:ok, token} -> {:ok, token}
          :none -> {:error, manual_fix_message()}
        end

      not Elicitation.client_supports_elicitation?() ->
        {:error, manual_fix_message()}

      not Elicitation.reachable?() ->
        # The client could answer a form, but this session holds no open
        # server-to-client stream to carry one — straight to guidance, never
        # a hang (m03.04 2.5.3).
        {:error, no_stream_message()}

      true ->
        elicit_fresh_token(session)
    end
  end

  @doc """
  Called when the retry with a freshly pasted token 401'd too: latches this
  session failed (no elicit loop on a bad paste), drops its verify guard,
  and returns the message.
  """
  @spec refreshed_token_rejected() :: String.t()
  def refreshed_token_rejected do
    if session = RequestSession.pid() do
      Sessions.mark_failed(session)
      Sessions.conclude_verify(session)
    end

    "The freshly pasted token was rejected too (401) — not asking again this " <>
      "session. " <> manual_fix_message()
  end

  @doc """
  Drop this session's verify guard. The client calls this in an `after`
  around the verify retry, so every exit — success, rejection, raise —
  clears it. Holder-only (`Sessions.conclude_verify/1`): a joiner's pass
  leaves the verifier's guard alone.
  """
  @spec verify_concluded() :: :ok
  def verify_concluded do
    if session = RequestSession.pid(), do: Sessions.conclude_verify(session)
    :ok
  end

  @doc """
  The recovery instructions every non-recovery 401 outcome carries — the
  HTTP flavor: the fix lives in the client config's Authorization header,
  not a launcher-host token file.
  """
  @spec manual_fix_message() :: String.t()
  def manual_fix_message do
    "DoItList rejected this session's API token (revoked or expired). Fix: put a " <>
      "fresh API token in the Authorization header of this server's entry in the " <>
      "MCP client configuration — Bearer <fresh token> — then reconnect this " <>
      "MCP server."
  end

  defp no_stream_message do
    "The operator can't be asked for a replacement — this session has no open " <>
      "server-to-client stream to carry the form. " <> manual_fix_message()
  end

  defp elicit_fresh_token(session) do
    case Elicitation.request(form_message(), @token_schema, timeout()) do
      {:ok, %{"action" => "accept", "content" => content}} when is_map(content) ->
        accept(session, String.trim(to_string(content["token"] || "")))

      {:ok, %{"action" => _declined_or_cancelled}} ->
        Sessions.mark_failed(session)
        {:error, "Token refresh declined — the call was not retried. " <> manual_fix_message()}

      {:error, :no_sse_handler} ->
        # The stream closed between the ladder's check and the send.
        {:error, no_stream_message()}

      {:error, _timeout_no_session_or_busy} ->
        # Not a refusal — don't latch; a later call may catch the operator
        # at the keyboard.
        {:error,
         "Asked the operator for a fresh token but got no answer — the call was not " <>
           "retried. Retry when they're available, or: " <> manual_fix_message()}
    end
  end

  defp accept(session, token) do
    if token != "" and Regex.match?(@token_format, token) do
      # Override installed BEFORE the caller's verify retry, guard up so a
      # concurrent 401 on this session joins instead of re-asking (2.20).
      # In-memory, keyed to the session — never persisted, never global.
      Sessions.put_override(session, token)
      Sessions.begin_verify(session)
      {:ok, token}
    else
      Sessions.mark_failed(session)

      {:error,
       "The pasted token wasn't usable (empty, or contains characters no token has) — " <>
         "nothing retried, not asking again this session. " <> manual_fix_message()}
    end
  end

  defp form_message do
    "DoItList rejected this session's API token (401 — likely revoked). Paste a " <>
      "fresh API token to continue: it takes effect immediately (the failed call " <>
      "retries once) and holds for this session only — nothing is stored. For " <>
      "future connects, update the Authorization header in this server's entry " <>
      "in the MCP client configuration. Or decline and update it there yourself."
  end

  defp timeout do
    Application.get_env(:doit_mcp, :token_recovery_timeout, @elicit_timeout)
  end
end
