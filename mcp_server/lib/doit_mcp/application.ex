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
      {DoitMcp.Server, transport: :stdio},
      # After the server, whose supervisor registers the stdio transport —
      # the watchdog looks it up by name and exits the VM when it stops
      # (client disconnect); `mix run --no-halt` alone would leak a zombie
      # adapter per session (m03.03 item 4.3.1.7).
      {DoitMcp.TransportWatchdog,
       transport: Anubis.Server.Registry.transport_name(DoitMcp.Server, :stdio)}
    ]
  end
end
