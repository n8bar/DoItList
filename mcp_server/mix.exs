defmodule DoitMcp.MixProject do
  use Mix.Project

  def project do
    [
      app: :doit_mcp,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {DoitMcp.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:anubis_mcp, "~> 1.10"},
      {:req, "~> 0.5"},
      # The HTTP transport serves the MCP plug resident (m03.04 item 23.1);
      # bandit pulls plug in for every env, not just :test.
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"}
    ]
  end
end
