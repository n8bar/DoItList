defmodule DoitMcp.TokenRecovery.Http do
  @moduledoc """
  Revoked-token recovery without config surgery (m03.04 2.3.1 + 23.3).

  A dead token still connects — the MCP handshake makes no API call — and
  then 401s every tool call; before this ladder, recovery meant hand-editing
  MCP client config. The whole policy is here, keyed to the session
  (`DoitMcp.TokenRecovery.Sessions`):

    * `credential/0` — the session's override when a paste installed one
      (`:unverified` until a call proves it), else the bearer header this
      request arrived with (`DoitMcp.SessionToken`); never a VM-wide token.
    * `recover/0` — a session's FIRST 401 sends the paste-a-fresh-token form
      on that session's own stream and RETURNS AT ONCE with the actionable
      error (m03.04 2.3.3) — a supervised waiter owns the human-paced wait.
      The paste is held in memory KEYED TO THAT SESSION only, over its header
      token for the rest of the session — never persisted, never visible to
      another session — and the next call proves it: a 401 there latches the
      session (no elicit loop on a bad paste); form open or paste unproven, a
      further 401 on the SAME session says so or reuses the paste, never a
      second form (2.3.2). Declined, cancelled, or unusable latches; a
      no-answer timeout does not; no open stream skips the form — straight to
      guidance. Valid-token sessions proceed untouched.

  The operator's lasting fix is the client's token source: the launching
  shell's env var, or the Authorization header in this server's MCP client
  config entry.
  """

  alias DoitMcp.{Elicitation, RequestSession, SessionToken}
  alias DoitMcp.TokenRecovery.Sessions

  # A generous paste window — a human has to go mint a token in the web app.
  @elicit_timeout to_timeout(minute: 5)

  # Tokens are url-base64-ish; a paste outside this set is never a token —
  # reject it before it burns the one verify.
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

  # The fact every 401 outcome states, and the lasting fix — an unmatched
  # token is most often the launching shell's env var, not a revocation.
  @no_match "No minted DoItList API token matches what this session presents."
  @source_fix "check DOITLIST_API_TOKEN in the shell that launched the client " <>
                "(or the Authorization header in the MCP client config), then reconnect."

  @doc """
  This request's API credential: the session's override if a paste installed
  one — `{:unverified, token}` until a call proves it — else the request's
  bearer header, else `:absent`.
  """
  @spec credential() :: {:ok, String.t()} | {:unverified, String.t()} | :absent
  def credential do
    with session when is_pid(session) <- RequestSession.pid(),
         {status, token} when status in [:verified, :unverified] <- Sessions.override(session) do
      if status == :verified, do: {:ok, token}, else: {:unverified, token}
    else
      _ -> SessionToken.fetch()
    end
  end

  @doc """
  The 401 policy — see the moduledoc ladder. Returns `{:ok, token}` when a
  paste already installed this session's replacement (the caller proves it
  with one attempt), or `{:error, message}` with the actionable message to
  surface instead of the bare 401 line — promptly, on every path.
  """
  @spec recover() :: {:ok, String.t()} | {:error, String.t()}
  def recover do
    case RequestSession.pid() do
      nil -> {:error, manual_fix_message()}
      session -> recover(session)
    end
  end

  defp recover(session) do
    case Sessions.override(session) do
      {:unverified, token} ->
        # A paste landed while this call's header attempt was out — the
        # override is this session's credential now: prove it rather than
        # raise a second form (the join, m03.04 2.3.2).
        {:ok, token}

      _verified_or_none ->
        cond do
          Sessions.failed?(session) ->
            {:error,
             "A replacement token was already declined or rejected this session — " <>
               "not asking again. " <> manual_fix_message()}

          not Elicitation.client_supports_elicitation?() ->
            {:error, manual_fix_message()}

          not Elicitation.reachable?() ->
            # The client could answer a form, but this session holds no open
            # server-to-client stream to carry one — straight to guidance,
            # never a hang (m03.04 2.2.1.3).
            {:error, no_stream_message()}

          true ->
            elicit_fresh_token(session)
        end
    end
  end

  @doc """
  Called when the pasted token's proving attempt 401'd too: latches this
  session failed (no elicit loop on a bad paste) and returns the message.
  """
  @spec refreshed_token_rejected() :: String.t()
  def refreshed_token_rejected do
    if session = RequestSession.pid(), do: Sessions.mark_failed(session)

    "The freshly pasted token was rejected too (401) — not asking again this " <>
      "session. " <> manual_fix_message()
  end

  @doc """
  Called when the pasted token's proving attempt got any answer short of a
  401: it is this session's proven credential from here on.
  """
  @spec refreshed_token_verified() :: :ok
  def refreshed_token_verified do
    if session = RequestSession.pid(), do: Sessions.mark_verified(session)
    :ok
  end

  @doc """
  The recovery instructions every non-recovery 401 outcome carries — the
  HTTP flavor: the fix lives at the client's token source, not a
  launcher-host token file.
  """
  @spec manual_fix_message() :: String.t()
  def manual_fix_message do
    @no_match <> " Fix: " <> @source_fix
  end

  defp no_stream_message do
    "The operator can't be asked for a replacement — this session has no open " <>
      "server-to-client stream to carry the form. " <> manual_fix_message()
  end

  # The form goes out on the session's stream; the call returns at once
  # (m03.04 2.3.3). The waiter lands the answer through land/2.
  defp elicit_fresh_token(session) do
    case Elicitation.request_async(form_message(), @token_schema, timeout(), &land(session, &1)) do
      :ok ->
        {:error,
         @no_match <>
           " A fresh-token form is open on the client — answer it, then re-call. Or " <>
           @source_fix}

      {:error, :already_waiting} ->
        {:error,
         "The fresh-token form is still open on the client — answer it, then re-call. Or " <>
           @source_fix}

      {:error, :no_sse_handler} ->
        # The stream closed between the ladder's check and the send.
        {:error, no_stream_message()}

      {:error, _no_session_or_waiter_died} ->
        {:error, manual_fix_message()}
    end
  end

  # Runs in the waiter when the operator answers: a usable paste installs
  # the override, unverified — the session's next call proves it; anything
  # else latches. In-memory, keyed to the session — never persisted, never
  # global. A no-answer timeout never reaches here, so it never latches.
  defp land(session, %{"action" => "accept", "content" => content}) when is_map(content) do
    token = String.trim(to_string(content["token"] || ""))

    if token != "" and Regex.match?(@token_format, token) do
      Sessions.put_override(session, token)
    else
      Sessions.mark_failed(session)
    end
  end

  defp land(session, _declined_or_cancelled), do: Sessions.mark_failed(session)

  defp form_message do
    @no_match <>
      " Paste a fresh token: the next call uses it, held for this session only — " <>
      "nothing is stored. Lasting fix: DOITLIST_API_TOKEN in the shell that launched " <>
      "the client (or the Authorization header in the MCP client config). Or decline " <>
      "and fix it there."
  end

  defp timeout do
    Application.get_env(:doit_mcp, :token_recovery_timeout, @elicit_timeout)
  end
end
