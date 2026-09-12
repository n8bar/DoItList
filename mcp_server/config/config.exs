import Config

# Test-only: route every DoitMcp.Client request through a Req.Test stub
# instead of the network, so tests never touch a live server.
if config_env() == :test do
  config :doit_mcp, req_options: [plug: {Req.Test, DoitMcp.Client}]

  # And the credential those requests carry when a test drives a tool
  # directly, outside the request task that installs a session's own bearer
  # (see DoitMcp.SessionToken).
  config :doit_mcp, session_token: {:ok, "test-token"}

  # anubis 1.10 logs session/transport lifecycle at debug; teardown-time
  # events land outside capture_log's window and would litter the suite
  # output. No test asserts on log content, so filter below warnings.
  config :logger, level: :warning
end
