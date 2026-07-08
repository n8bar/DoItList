defmodule DoitMcp.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(children(Mix.env()), strategy: :one_for_one, name: DoitMcp.Supervisor)
  end

  # Tests exercise tool/resource modules directly against a Req.Test stub —
  # they never need a live stdio transport, and starting one under `mix
  # test` would fight ExUnit for stdin/stdout. Only boot it for real runs.
  def children(:test), do: []

  def children(_env) do
    [
      # Anubis expires idle sessions after 30 minutes by default, but on
      # stdio the pipe outlives the session: a long-idle client's next
      # request hit an uninitialized replacement session and got -32600
      # (m03.03 item 4.3.1.8). nil is not infinity here (anubis falls back
      # to the default), so pin the session open with a large timeout —
      # kept under Process.send_after's ceiling of 4_294_967_295 ms
      # (~49.7 days; larger raises badarg).
      {DoitMcp.Server, transport: :stdio, session_idle_timeout: to_timeout(day: 49)},
      # After the server, whose supervisor registers the stdio transport —
      # the watchdog looks it up by name and exits the VM when it stops
      # (client disconnect); `mix run --no-halt` alone would leak a zombie
      # adapter per session (m03.03 item 4.3.1.7).
      {DoitMcp.TransportWatchdog,
       transport: Anubis.Server.Registry.transport_name(DoitMcp.Server, :stdio)}
    ]
  end
end
