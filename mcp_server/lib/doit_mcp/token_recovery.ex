defmodule DoitMcp.TokenRecovery do
  @moduledoc """
  Revoked-token recovery without config surgery (m03.04 item 2.13).

  A dead token still connects — the stdio handshake makes no API call — and
  then 401s every tool call; before this module, recovery meant hand-editing
  MCP client config. This module owns the whole ladder:

    * `token/0` — the session's current bearer token: the in-process override
      a successful refresh installed, else the launcher-provided
      `DOITLIST_API_TOKEN` env.
    * `recover/0` — the 401 policy `DoitMcp.Client` runs centrally, so every
      tool and resource inherits it. On an elicitation-capable client, the
      FIRST 401 of the session raises a form asking for a fresh token; the
      accepted answer swaps the token in-process (the failed call retries
      once) and persists it for the launcher's next connect. A declined
      form, an unusable paste, or a refreshed token that 401s again latches
      the session failed — later 401s go straight to the actionable error,
      never a re-prompt loop. A no-answer timeout does NOT latch: the
      operator merely wasn't there, so a later call may ask again. Clients
      without the capability get the actionable error immediately. While an
      accepted token's verify retry is in flight, a concurrent 401 joins
      that recovery — it retries with the installed override instead of
      raising a second form (the verify-in-flight guard, m03.04 2.20).

  ## Persistence across the container boundary

  The adapter runs inside the `web` container; the launcher and its token
  sources live on the host. The repo bind mount (`.:/app`) is the one path
  that already crosses that boundary, so a refreshed token is written to
  `/app/.doitlist/mcp-refreshed-token.env` (git-ignored, 0600, chowned to
  the repo's owner so the host-side launcher — not just container root —
  can read it). `bin/mcp_server.sh` sources the newest of that file and
  `~/.config/doitlist/mcp.env` on each connect; see its comments for the
  full precedence.

  The token persists as soon as the form is accepted, before the retry
  verifies it: every other known token is already dead at that point, so a
  bad paste loses nothing — and a later hand-edit of `mcp.env` is newer, so
  it wins the launcher's freshest-file rule anyway.

  Session state (the override and the failed latch) lives in app env: stdio
  is one session per OS process, so process lifetime IS session lifetime,
  and a reconnect naturally resets both.
  """

  alias DoitMcp.Elicitation

  require Logger

  # The verify-in-flight guard (m03.04 2.20): the process that accepted a
  # fresh token registers under this name until its verify retry concludes.
  # Same atomic primitive as the elicitation waiter — and a registered name
  # dies with its process, so a killed verifier can never wedge recovery.
  @verifying DoitMcp.TokenRecovery.Verifying

  @env_var "DOITLIST_API_TOKEN"
  @default_persist_path "/app/.doitlist/mcp-refreshed-token.env"
  @default_env_file "~/.config/doitlist/mcp.env"

  # A human has to go mint a token in the web app — same generous window as
  # the import gate's readback confirm.
  @elicit_timeout to_timeout(minute: 5)

  # The launcher SOURCES the persisted file (`. file`) — a pasted "token"
  # smuggling shell metacharacters would execute on the host. Tokens are
  # url-base64-ish; anything outside this set is rejected outright and never
  # written.
  @token_format ~r|\A[A-Za-z0-9._+/=-]+\z|

  @token_schema %{
    "type" => "object",
    "properties" => %{
      "token" => %{
        "type" => "string",
        "description" =>
          "A fresh DoItList API token — replaces the rejected one for this session " <>
            "and, persisted, for future connects"
      }
    },
    "required" => ["token"]
  }

  @doc """
  The bearer token requests go out with: the override an in-session refresh
  installed, else the env the launcher resolved at connect.
  """
  @spec token() :: String.t()
  def token do
    Application.get_env(:doit_mcp, :token_override) || System.fetch_env!(@env_var)
  end

  @doc """
  The 401 policy — see the moduledoc ladder. Returns `{:ok, fresh_token}`
  when the operator supplied a usable replacement (already swapped in and
  persisted; the caller retries once with it), or `{:error, message}` with
  the actionable message to surface instead of the bare 401 line.
  """
  @spec recover() :: {:ok, String.t()} | {:error, String.t()}
  def recover do
    cond do
      failed?() ->
        {:error,
         "A replacement token was already declined or rejected this session — " <>
           "not asking again. " <> manual_fix_message()}

      verifying?() ->
        # A fresh token was accepted moments ago and its verify retry is still
        # in flight — the accept→retry window (m03.04 2.20). Join that
        # recovery: retry with the installed override instead of raising a
        # second form. If the override is dead too, this caller's retry
        # latches the session exactly like the verifier's would.
        {:ok, token()}

      not capable?() ->
        {:error, manual_fix_message()}

      true ->
        elicit_fresh_token()
    end
  end

  @doc """
  Whether a freshly accepted token's verify retry is still in flight — the
  window where `recover/0` joins the ongoing recovery rather than eliciting
  again (m03.04 2.20).
  """
  @spec verifying?() :: boolean()
  def verifying?, do: Process.whereis(@verifying) != nil

  @doc """
  Drop the verify-in-flight guard. The client calls this in an `after` around
  the verify retry, so every exit — success, rejection, raise — clears it.
  Holder-only: a joiner concluding its own retry leaves the verifier's guard
  alone, and a verifier killed outright needs no call at all (the registered
  name dies with it).
  """
  @spec verify_concluded() :: :ok
  def verify_concluded do
    if Process.whereis(@verifying) == self(), do: Process.unregister(@verifying)
    :ok
  rescue
    # The name emptied between the check and the unregister — already clear.
    ArgumentError -> :ok
  end

  @doc """
  Called when the retry with a freshly pasted token 401'd too: latches the
  failed state (no elicit loop on a bad paste) and returns the message.
  """
  @spec refreshed_token_rejected() :: String.t()
  def refreshed_token_rejected do
    mark_failed()
    verify_concluded()

    "The freshly pasted token was rejected too (401) — not asking again this session. " <>
      manual_fix_message()
  end

  @doc """
  The recovery instructions every non-recovery 401 outcome carries: names the
  operator-editable token file (the real host path when the launcher passed
  `DOITLIST_MCP_ENV_PATH` through) and the paste-a-fresh-token fix.
  """
  @spec manual_fix_message() :: String.t()
  def manual_fix_message do
    "DoItList rejected this session's API token (revoked or expired). Fix without " <>
      "touching MCP client config: put a fresh API token in #{env_file()} on the " <>
      "launcher host — one line, DOITLIST_API_TOKEN=<fresh token> — then reconnect " <>
      "this MCP server. The launcher reads that file on every connect and it beats " <>
      "the token in the client config's env."
  end

  @doc """
  Write the refreshed token where the launcher's next connect will read it
  (`:token_persist_path` app env, default `#{@default_persist_path}` — the
  repo bind mount carries it to the host). Best-effort: a failure is logged
  to stderr, never fatal — the in-process swap already happened and this
  session keeps working.
  """
  @spec persist(String.t()) :: :ok | {:error, term()}
  def persist(token) do
    path = persist_path()
    dir = Path.dirname(path)

    # Lock the dir to 0700 BEFORE writing the token, so the brief window where
    # the new file still carries the umask default (often 0644) is unreachable —
    # nobody but the owner can traverse a 0700 dir to open it.
    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         :ok <- File.write(path, persist_content(token)),
         :ok <- File.chmod(path, 0o600) do
      align_ownership(dir, path)
    else
      {:error, reason} = error ->
        Logger.warning("could not persist refreshed token to #{path}: #{inspect(reason)}")
        error
    end
  end

  @doc "Forget the session's override, failed latch, and verify guard (tests)."
  @spec reset() :: :ok
  def reset do
    Application.delete_env(:doit_mcp, :token_override)
    Application.delete_env(:doit_mcp, :token_recovery_failed)
    # Force-clear regardless of holder — test cleanup only.
    if Process.whereis(@verifying), do: Process.unregister(@verifying)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp elicit_fresh_token do
    case elicit().(form_message(), @token_schema, timeout()) do
      {:ok, %{"action" => "accept", "content" => content}} when is_map(content) ->
        accept(String.trim(to_string(content["token"] || "")))

      {:ok, %{"action" => _declined_or_cancelled}} ->
        mark_failed()
        {:error, "Token refresh declined — the call was not retried. " <> manual_fix_message()}

      {:error, _timeout_no_session_or_busy} ->
        # Not a refusal — don't latch; a later call may catch the operator
        # at the keyboard.
        {:error,
         "Asked the operator for a fresh token but got no answer — the call was not " <>
           "retried. Retry when they're available, or: " <> manual_fix_message()}
    end
  end

  defp accept(token) do
    if token != "" and Regex.match?(@token_format, token) do
      Application.put_env(:doit_mcp, :token_override, token)
      _ = persist(token)
      register_verifying()
      {:ok, token}
    else
      mark_failed()

      {:error,
       "The pasted token wasn't usable (empty, or contains characters no token has) — " <>
         "nothing retried, not asking again this session. " <> manual_fix_message()}
    end
  end

  defp form_message do
    "DoItList rejected this session's API token (401 — likely revoked). Paste a " <>
      "fresh API token to continue: it takes effect immediately (the failed call " <>
      "retries once) and is saved so future connects use it — no MCP client config " <>
      "changes needed. Or decline and put it in #{env_file()} on the launcher host " <>
      "yourself."
  end

  @doc false
  # Public only so the launcher's read-side safety check can be tested against
  # the exact bytes this writes — never call it outside persist/1 or that test.
  def persist_content(token) do
    """
    # Written by the DoItList MCP adapter after an in-session token refresh
    # (m03.04 item 2.13). bin/mcp_server.sh sources the newest of this file
    # and #{@default_env_file} on each connect.
    #{@env_var}=#{token}
    """
  end

  # The container runs as root while the repo mount belongs to the host user;
  # a root-owned 0600 file would be unreadable to the host-side launcher.
  # Match the repo root's owner instead; best-effort (a non-root container
  # that can write the mount already matches).
  defp align_ownership(dir, path) do
    case File.stat(Path.dirname(dir)) do
      {:ok, %File.Stat{uid: uid, gid: gid}} ->
        _ = :file.change_owner(String.to_charlist(dir), uid, gid)
        _ = :file.change_owner(String.to_charlist(path), uid, gid)
        :ok

      _ ->
        :ok
    end
  end

  # Guard up BEFORE `{:ok, token}` sends the caller into its verify retry
  # (m03.04 2.20). The elicitation waiter unregistered before accept runs, so
  # this process carries no name; a collision means a prior guard leaked
  # (shouldn't happen — the client's `after` covers every verifier exit) and
  # already-guarded is the correct reading.
  defp register_verifying do
    Process.register(self(), @verifying)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp mark_failed, do: Application.put_env(:doit_mcp, :token_recovery_failed, true)
  defp failed?, do: Application.get_env(:doit_mcp, :token_recovery_failed, false)

  defp persist_path do
    Application.get_env(:doit_mcp, :token_persist_path, @default_persist_path)
  end

  # The real host path of the operator's token file, passed through by the
  # launcher; the default matches its default so the message stays truthful
  # even under a bare `docker compose exec` run.
  defp env_file do
    System.get_env("DOITLIST_MCP_ENV_PATH", @default_env_file)
  end

  # Injectable seams (tests): the capability check and the elicitation call.
  defp capable? do
    Application.get_env(
      :doit_mcp,
      :token_recovery_capable,
      &Elicitation.client_supports_elicitation?/0
    ).()
  end

  defp elicit do
    Application.get_env(:doit_mcp, :token_recovery_elicit, &Elicitation.request/3)
  end

  defp timeout do
    Application.get_env(:doit_mcp, :token_recovery_timeout, @elicit_timeout)
  end
end
