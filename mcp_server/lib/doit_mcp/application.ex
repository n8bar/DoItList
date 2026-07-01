defmodule DoitMcp.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # Tests exercise tool/resource modules directly against a Req.Test stub —
    # they never need a live stdio transport, and starting one under `mix
    # test` would fight ExUnit for stdin/stdout. Only boot it for real runs.
    children =
      if Mix.env() == :test do
        []
      else
        [{DoitMcp.Server, transport: :stdio}]
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: DoitMcp.Supervisor)
  end
end
