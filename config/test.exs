import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :doit, DoIt.Repo,
  username: System.get_env("DB_USERNAME", "postgres"),
  password: System.get_env("DB_PASSWORD", "postgres"),
  hostname: System.get_env("DB_HOSTNAME", "localhost"),
  database:
    "#{System.get_env("DB_DATABASE", "doit")}_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# The server runs during test so browser (e2e) tests can reach it from the
# `playwright` compose service — hence 0.0.0.0, not loopback. Plain test runs
# just carry an idle listener on 4002.
config :doit, DoItWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4002],
  secret_key_base: "aVBF9NZ50c4znU3AQ+5KCsqvxVG8aYHOI3a1U+9RRQMxb3fzaZ8BKXBESr8kVWN9",
  server: true,
  # e2e browsers reach us by container IP, which never matches the url host.
  check_origin: false

# Browser (e2e) tests; ws_endpoint and base_url are set at runtime in
# test/test_helper.exs, only when e2e tests are actually requested.
config :phoenix_test, otp_app: :doit

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
