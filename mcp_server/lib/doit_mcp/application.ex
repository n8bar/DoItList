defmodule DoitMcp.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # Before anything can log: no dep's error path may write a credential to
    # the container log (m03.04 item 23.7). Transport-independent — stdio's
    # stderr is teed to a host file, which is the same disclosure.
    :ok = DoitMcp.LogRedaction.install()

    mode = transport_mode()

    # The VM runs exactly one transport for its lifetime; record which, so
    # DoitMcp.Client can resolve the API credential per mode (m03.04 item
    # 23.2) without re-reading the environment on every request.
    Application.put_env(:doit_mcp, :transport_mode, mode)

    # Same one-read-at-boot treatment for the frame-log switch (m03.04 item
    # 23.5): capture is on unless DOITLIST_MCP_FRAME_LOGS says off.
    Application.put_env(:doit_mcp, :frame_logs, DoitMcp.FrameLog.env_enabled?())

    Supervisor.start_link(children(Mix.env(), mode),
      strategy: :one_for_one,
      name: DoitMcp.Supervisor
    )
  end

  @doc """
  The transport this VM serves: `DOITLIST_MCP_TRANSPORT=http` boots the
  resident streamable-HTTP tree (m03.04 item 23.1); anything else — unset,
  `stdio` — keeps the launcher-spawned stdio tree.
  """
  def transport_mode(env_value \\ System.get_env("DOITLIST_MCP_TRANSPORT"))
  def transport_mode("http"), do: :http
  def transport_mode(_env_value), do: :stdio

  # Tests exercise tool/resource modules directly against a Req.Test stub —
  # they never need a live transport, and starting one under `mix test`
  # would fight ExUnit for stdin/stdout (or a port). Only boot it for real
  # runs.
  def children(env, mode \\ :stdio)

  def children(:test, _mode), do: []

  def children(_env, :http) do
    [
      # The import gate's confirm memory, keyed per session (m03.04 item
      # 23.6) — before the transport tree so a tool call can never race
      # its start.
      DoitMcp.ImportGate.Counter,
      # Session-keyed elicitation waiters and per-session 401-recovery state
      # (m03.04 item 23.3) — same never-race-a-tool-call ordering.
      {Registry, keys: :unique, name: DoitMcp.Elicitation.Registry},
      DoitMcp.TokenRecovery.Sessions,
      # Per-session frame capture (m03.04 item 23.5) — before the transport
      # tree so a session's first frame can't outrun the logger.
      DoitMcp.FrameLog,
      # The stock anubis streamable-HTTP tree: session registry + dynamic
      # session supervisor + transport, one session process per connected
      # client. Deliberately NO timeout options: anubis's stock 30-minute
      # idle expiry is right here (m03.04 item 23.4) — an expired session
      # re-initializes from a live client in milliseconds, so none of the
      # stdio tree's lifecycle machinery (49-day pin, substantive-idle
      # reaper, watchdog) applies. `start: true` skips the dep's web-server
      # heuristics; the Bandit listener below is that server.
      {DoitMcp.Server, transport: {:streamable_http, start: true}},
      # The listener serving our wrapper around anubis's MCP plug — client
      # answers to server-initiated requests take the immediate session call
      # path, everything else the stock plug (m03.04 item 23.3; see
      # DoitMcp.Http.Plug) — after the tree it routes into. In-container
      # bind is fixed; compose maps the host port (MCP_PORT, default 4004).
      {Bandit, plug: {DoitMcp.Http.Plug, server: DoitMcp.Server}, ip: {0, 0, 0, 0}, port: 4004}
    ]
  end

  def children(_env, _mode) do
    [
      # The import gate's confirm memory, keyed per session on this
      # transport too (m03.04 item 23.6 — stdio is one session per VM) —
      # before the stdio tree so a tool call can never race its start.
      DoitMcp.ImportGate.Counter,
      # Elicitation waiters key on the session process on every transport
      # (m03.04 item 23.3) — stdio's single session included.
      {Registry, keys: :unique, name: DoitMcp.Elicitation.Registry},
      # The stdio tree (m03.04 item 3.11.1): anubis Session plus our own
      # concurrent read/dispatch transport — the stock one blocked the
      # reader on every request, so an elicitation answer could never
      # arrive. Anubis expires idle sessions after 30 minutes by default,
      # but on stdio the pipe outlives the session: a long-idle client's
      # next request hit an uninitialized replacement session and got -32600
      # (m03.04 item 3.2). nil is not infinity here (anubis falls back
      # to the default), so pin the session open with a large timeout —
      # kept under Process.send_after's ceiling of 4_294_967_295 ms
      # (~49.7 days; larger raises badarg). The pin sidelines that expiry
      # rather than replacing it: the session resets it on every inbound
      # frame, pings included, so an abandoned client that keeps pinging
      # would hold the adapter forever. The transport's substantive-idle
      # window reaps those — 2 hours without a non-ping frame stops the
      # transport and the watchdog below halts the VM (m03.04 item 22).
      {DoitMcp.Stdio.Supervisor,
       session_idle_timeout: to_timeout(day: 49), substantive_idle_timeout: to_timeout(hour: 2)},
      # After the stdio tree, which registers the transport under the same
      # anubis registry name the stock one used — the watchdog looks it up
      # by name and exits the VM when it stops (client disconnect); `mix run
      # --no-halt` alone would leak a zombie adapter per session (m03.04
      # item 2.1).
      {DoitMcp.TransportWatchdog,
       transport: Anubis.Server.Registry.transport_name(DoitMcp.Server, :stdio)}
    ]
  end
end
