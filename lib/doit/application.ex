defmodule DoIt.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      DoItWeb.Telemetry,
      DoIt.Repo,
      {DNSCluster, query: Application.get_env(:doit, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: DoIt.PubSub},
      DoItWeb.Presence,
      # Start a worker by calling: DoIt.Worker.start_link(arg)
      # {DoIt.Worker, arg},
      # Start to serve requests, typically the last entry
      DoItWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DoIt.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DoItWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
