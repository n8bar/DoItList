# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :doit,
  namespace: DoIt,
  ecto_repos: [DoIt.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :doit, DoItWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: DoItWeb.ErrorHTML, json: DoItWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: DoIt.PubSub,
  live_view: [signing_salt: "SD3UH6HL"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  doit: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  doit: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# HTTP API rate limits (m03.01 worklist 1.5). `limit` requests per `window_ms`
# window, per token; `ip_limit` is the coarser pre-auth per-IP cap that also
# meters unauthenticated traffic. config/test.exs tunes these so tests can trip
# a per-token 429 in a few requests without the per-IP cap interfering.
config :doit, DoIt.Api.RateLimiter,
  limit: 120,
  window_ms: 60_000,
  ip_limit: 600

# Roll-up recompute routing (m03.02 item 4). :async defers ancestor-chain
# recomputes to the per-Initiative DoIt.Tasks.RollupDebounce (one coalesced
# pass per debounce window — a write's own row still updates synchronously);
# :inline runs them in the triggering transaction. config/test.exs pins
# :inline so the suite stays deterministic.
config :doit, :rollup_recompute, :async

# Debounce tuning: flush after debounce_ms of quiet, but never later than
# max_wait_ms after a window's first enqueue.
config :doit, DoIt.Tasks.RollupDebounce,
  debounce_ms: 150,
  max_wait_ms: 500

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
