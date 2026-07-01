import Config

# stdio IS the wire protocol here — anything else written to stdout corrupts
# the JSON-RPC stream for whatever MCP client spawned this process. Elixir's
# default Logger console backend writes to stdout; route it to stderr instead
# so log lines never interleave with protocol frames.
config :logger, :default_handler, config: [type: :standard_error]

# Test-only: route every DoitMcp.Client request through a Req.Test stub
# instead of the network, so tests never touch a live server.
if config_env() == :test do
  config :doit_mcp, req_options: [plug: {Req.Test, DoitMcp.Client}]
end
