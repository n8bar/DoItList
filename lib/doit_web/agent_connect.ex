defmodule DoItWeb.AgentConnect do
  @moduledoc "Composes the agent-facing MCP endpoint URL from instance config."

  @doc """
  The public URL agents connect to, with exactly one trailing slash.

  `:mcp_public_url` (full override, for scheme/port differences like hosted
  TLS) wins; otherwise the web endpoint's public host plus `:mcp_public_port`
  compose it.
  """
  def mcp_url do
    case Application.get_env(:doit, :mcp_public_url) do
      v when v in [nil, ""] ->
        host = DoItWeb.Endpoint.struct_url().host
        port = Application.get_env(:doit, :mcp_public_port, 4004)
        "http://#{host}:#{port}/"

      url ->
        String.trim_trailing(url, "/") <> "/"
    end
  end
end
