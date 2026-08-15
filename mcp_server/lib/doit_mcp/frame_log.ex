defmodule DoitMcp.FrameLog do
  @moduledoc """
  Per-session frame capture for the resident HTTP transport (m03.04 item
  23.5): transport debugging needs the exact bytes a client sent when a
  request comes back wrong, without any client-side setup.

  One JSONL file per session under `/tmp/doitlist-mcp` INSIDE the container —
  ephemeral with it, and deliberately not under `/app`, which is the
  repository bind mount. Files are named `<session id>.<start>.jsonl` and
  each line is `{"ts", "dir", "frame"}`, where `dir` is `"in"` (client to
  server) or `"out"`.

  This service is multi-user, so NO credential material is written.
  Redaction is structural, not a scrub of the encoded line: a `token` field
  (the 401-recovery form's answer, see `DoitMcp.TokenRecovery.Http`), an
  `authorization` field, and any value that IS a bearer header are replaced
  wherever they appear in a frame.

  Capture is on by default; `DOITLIST_MCP_FRAME_LOGS=off` turns it off, read
  once at boot by `DoitMcp.Application`.

  Logging never breaks serving: writes are casts, redacted and stamped in the
  caller so no secret ever sits in this process's mailbox, and a write that
  fails degrades to one warning for the life of the VM while the session
  keeps being served.
  """

  use GenServer

  alias DoitMcp.Redaction

  require Logger

  @default_root "/tmp/doitlist-mcp"

  # Frames that arrive before their session has an id (an `initialize` whose
  # answer assigns one, or a request that never gets that far).
  @unassigned "unassigned"

  # The resident VM outlives every session it serves, so the id-to-path map
  # is bounded; a pruned session that speaks again simply opens a new file.
  @max_sessions 256

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Whether capture is on. Read once at boot into app env from
  `DOITLIST_MCP_FRAME_LOGS` (see `env_enabled?/1`); tests set it directly.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:doit_mcp, :frame_logs, true)

  @doc """
  The boot reading of the switch: `off` disables capture entirely, anything
  else — unset included — leaves it on.
  """
  @spec env_enabled?(String.t() | nil) :: boolean()
  def env_enabled?(env_value \\ System.get_env("DOITLIST_MCP_FRAME_LOGS"))
  def env_enabled?("off"), do: false
  def env_enabled?(_env_value), do: true

  @doc """
  Record one frame against a session. `dir` is `:in` for what the client
  sent, `:out` for what the server wrote back. A nil session id buckets into
  the pre-session file.
  """
  @spec capture(String.t() | nil, :in | :out, term()) :: :ok
  def capture(session_id, dir, frame) when dir in [:in, :out] do
    if enabled?() do
      GenServer.cast(
        __MODULE__,
        {:frame, session_id || @unassigned, dir, redact(frame), stamp()}
      )
    end

    :ok
  end

  @doc """
  Replace every credential-bearing field of a decoded frame: a `token` or
  `authorization` field at any depth, and any value that is itself a bearer
  header. Shapes and replacements are `DoitMcp.Redaction`'s, shared with the
  log filter (m03.04 2.2.1.7).
  """
  @spec redact(term()) :: term()
  def redact(frame) when is_map(frame) do
    Map.new(frame, fn {key, value} ->
      case Redaction.replacement_for(key) do
        nil -> {key, redact(value)}
        replacement -> {key, replacement}
      end
    end)
  end

  def redact(frame) when is_list(frame), do: Enum.map(frame, &redact/1)

  def redact(frame), do: Redaction.redact_value(frame)

  @impl GenServer
  def init(_opts) do
    {:ok,
     %{
       root: Application.get_env(:doit_mcp, :frame_log_root, @default_root),
       files: %{},
       seq: 0,
       warned?: false
     }}
  end

  @impl GenServer
  def handle_cast({:frame, session_id, dir, frame, ts}, state) do
    line = JSON.encode!(%{"ts" => ts, "dir" => Atom.to_string(dir), "frame" => frame})
    {:noreply, append(state, session_id, line <> "\n")}
  rescue
    error -> {:noreply, warn_once(state, error)}
  end

  defp append(state, session_id, line) do
    case path_for(state, session_id) do
      {:ok, path, state} ->
        case File.write(path, line, [:append]) do
          :ok -> state
          {:error, reason} -> warn_once(state, reason)
        end

      {:error, state} ->
        state
    end
  end

  defp path_for(state, session_id) do
    case Map.fetch(state.files, session_id) do
      {:ok, {path, _seq}} -> {:ok, path, remember(state, session_id, path)}
      :error -> create(state, session_id)
    end
  end

  # The session's file, created on its first frame. The BEAM has no umask
  # control, so the 0700 directory is what closes the moment between creating
  # a file and restricting it.
  defp create(state, session_id) do
    path = Path.join(state.root, filename(session_id))

    with :ok <- File.mkdir_p(state.root),
         :ok <- File.chmod(state.root, 0o700),
         :ok <- File.touch(path),
         :ok <- File.chmod(path, 0o600) do
      {:ok, path, remember(state, session_id, path)}
    else
      {:error, reason} -> {:error, warn_once(state, reason)}
    end
  end

  defp filename(session_id) do
    stamp = NaiveDateTime.local_now() |> Calendar.strftime("%Y%m%dT%H%M%S")
    "#{sanitize(session_id)}.#{stamp}.jsonl"
  end

  # Session ids are the transport's to mint; never let one name a path. The
  # allowed set covers the ids anubis generates (url-base64 with padding), so
  # a file is still findable by the session id in a log line.
  defp sanitize(session_id) do
    session_id
    |> String.replace(~r/[^A-Za-z0-9._=-]/, "_")
    |> String.slice(0, 64)
  end

  defp remember(state, session_id, path) do
    state = %{state | seq: state.seq + 1}
    files = Map.put(state.files, session_id, {path, state.seq})
    %{state | files: prune(files)}
  end

  defp prune(files) when map_size(files) <= @max_sessions, do: files

  defp prune(files) do
    files
    |> Enum.sort_by(fn {_session_id, {_path, seq}} -> seq end, :desc)
    |> Enum.take(div(@max_sessions, 2))
    |> Map.new()
  end

  defp warn_once(%{warned?: true} = state, _reason), do: state

  defp warn_once(state, reason) do
    Logger.warning(
      "frame log write failed (#{inspect(reason)}) — serving continues; " <>
        "further capture failures stay silent"
    )

    %{state | warned?: true}
  end

  # The container's clock, matching the timestamps on its log lines.
  defp stamp, do: NaiveDateTime.local_now() |> NaiveDateTime.to_iso8601()
end
