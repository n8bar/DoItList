defmodule DoitMcp.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # Before anything can log: no dep's error path may write a credential to
    # the container log (m03.04 2.2.1.7).
    :ok = DoitMcp.LogRedaction.install()

    # One read at boot for the frame-log switch (m03.04 2.2.1.5): capture
    # is on unless DOITLIST_MCP_FRAME_LOGS says off.
    Application.put_env(:doit_mcp, :frame_logs, DoitMcp.FrameLog.env_enabled?())

    Supervisor.start_link(children(Mix.env()),
      strategy: :one_for_one,
      name: DoitMcp.Supervisor
    )
  end

  # Tests exercise tool/resource modules directly against a Req.Test stub —
  # they never need a live transport, and starting one under `mix test`
  # would fight ExUnit for the port. Only boot it for real runs.
  def children(:test), do: []

  def children(_env) do
    [
      # The import classifier's record memory, keyed per session (m03.04
      # item 23.6) — before the transport tree so a tool call can never
      # race its start.
      DoitMcp.ImportGate.Counter,
      # Session-keyed elicitation waiters and per-session 401-recovery state
      # (m03.04 2.2.1.3) — same never-race-a-tool-call ordering.
      {Registry, keys: :unique, name: DoitMcp.Elicitation.Registry},
      DoitMcp.TokenRecovery.Sessions,
      # Per-session frame capture (m03.04 2.2.1.5) — before the transport
      # tree so a session's first frame can't outrun the logger.
      DoitMcp.FrameLog,
      # The stock anubis streamable-HTTP tree: session registry + dynamic
      # session supervisor + transport, one session process per connected
      # client. Deliberately NO timeout options: anubis's stock 30-minute
      # idle expiry is right here (m03.04 2.2.1.4) — an expired session
      # re-initializes from a live client in milliseconds. `start: true`
      # skips the dep's web-server heuristics; the Bandit listener below is
      # that server.
      {DoitMcp.Server, transport: {:streamable_http, start: true}},
      # The listener serving our wrapper around anubis's MCP plug — client
      # answers to server-initiated requests take the immediate session call
      # path, everything else the stock plug (m03.04 2.2.1.3; see
      # DoitMcp.Http.Plug) — after the tree it routes into. In-container
      # bind is fixed; compose maps the host port (MCP_PORT, default 4004).
      {Bandit, plug: {DoitMcp.Http.Plug, server: DoitMcp.Server}, ip: {0, 0, 0, 0}, port: 4004}
    ]
  end
end
