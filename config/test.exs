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

# We don't run a server during test. If one is required,
# you can enable the server option below. Port 4002 keeps the test env clear
# of the dev server's PORT (see config/runtime.exs).
config :doit, DoItWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "aVBF9NZ50c4znU3AQ+5KCsqvxVG8aYHOI3a1U+9RRQMxb3fzaZ8BKXBESr8kVWN9",
  server: false

# Full-cost password hashing is pure waste in tests — nearly every LiveView
# test registers + logs in a user, paying ~hundreds of ms of bcrypt each.
config :bcrypt_elixir, :log_rounds, 1

# Small per-token API rate limit so tests trip a 429 deterministically within a
# single window (m03.01 worklist 1.5). The window is long enough that a test's
# burst stays in one window; each test mints a fresh token (unique id → unique
# counter key), so counts don't bleed across tests.
config :doit, DoIt.Api.RateLimiter,
  limit: 5,
  window_ms: 60_000,
  # The per-IP cap is shared by every ConnCase request (all from 127.0.0.1), so
  # keep it far above any single suite's request count: the per-token cap is
  # what those tests assert on, while the per-IP throttle is exercised directly
  # in its own unit test with an isolated remote_ip and a small override.
  ip_limit: 100_000

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
