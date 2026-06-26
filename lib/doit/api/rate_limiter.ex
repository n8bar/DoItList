defmodule DoIt.Api.RateLimiter do
  @moduledoc """
  Per-token fixed-window rate limiter for the HTTP API (m03.01 worklist 1.5).

  A tiny GenServer owns a named public ETS table; the hot path
  (`check_rate/2`) is a lock-free `:ets.update_counter/4`, so it doesn't funnel
  every request through the GenServer. No new dependency.

  ## Window model

  Fixed window. The key is `{token_id, window_index}` where
  `window_index = div(now_ms, window_ms)`. The first request in a window creates
  the counter; each request increments it. When the count exceeds the limit the
  request is rejected with the number of seconds until the window rolls over,
  surfaced to the client as `Retry-After`.

  Because it's a *fixed* (not sliding) window, a client can send up to
  `2 * limit` requests across a single window boundary — `limit` in the tail of
  window N plus `limit` in the head of window N+1. That's the accepted tradeoff
  for a lock-free counter: these budgets are coarse abuse caps, not exact
  quotas.

  ## Reclaiming stale windows

  Each `{token_id, window_index}` counter belongs to exactly one window and is
  dead weight the moment that window elapses (the hot path only ever touches the
  *current* window's key). Left alone the table would grow one row per token per
  window forever. A periodic sweep (`handle_info(:sweep, …)`, every `sweep_ms`)
  reclaims it: `:ets.select_delete/2` removes every row whose `window_index` is
  below the current window, so the table stays proportional to *active* tokens,
  not to elapsed time. `sweep_expired/1` is also callable directly (tests).

  ## Durability tradeoff

  The table is owned by this GenServer. The hot path never funnels external
  input through the process — it's a lock-free `:ets.update_counter/4` — and the
  process handles only its own `:sweep` timer, so API traffic can't crash it.
  Were the process to restart, the table (and every counter) would be rebuilt
  empty: the limiter fails *open*, which is the safe direction for an
  availability guard. Surviving a restart would need a dedicated table owner /
  heir; that durability isn't worth the extra moving part here.

  ## Tunability (config)

      config :doit, #{inspect(__MODULE__)},
        limit: 120,         # max requests per window, per token
        window_ms: 60_000,  # window length in milliseconds
        ip_limit: 600,      # pre-auth per-IP cap (DoItWeb.Api.IpRateLimitPlug)
        sweep_ms: 300_000   # how often stale-window rows are reclaimed

  `config/test.exs` sets a small limit so tests trip `429` deterministically.
  `check_rate/2` also accepts `:limit` / `:window_ms` overrides for direct unit
  tests.
  """
  use GenServer

  @table :doit_api_rate_limit
  @default_limit 120
  @default_window_ms 60_000
  @default_sweep_ms 300_000

  # --- Public API ------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record a request for `token_id` and decide whether it's allowed.

  Returns `:ok`, or `{:error, retry_after_seconds}` when the per-window limit
  is exceeded. `opts` may override `:limit` and `:window_ms` (defaults come from
  config).
  """
  def check_rate(token_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, config(:limit, @default_limit))
    window_ms = Keyword.get(opts, :window_ms, config(:window_ms, @default_window_ms))

    now_ms = System.system_time(:millisecond)
    window_index = div(now_ms, window_ms)
    key = {token_id, window_index}

    count = :ets.update_counter(@table, key, {2, 1}, {key, 0})

    if count <= limit do
      :ok
    else
      window_end = (window_index + 1) * window_ms
      retry_after = max(0, ceil_div(window_end - now_ms, 1000))
      {:error, retry_after}
    end
  end

  @doc """
  Delete counters for windows that have fully elapsed — every row whose
  `window_index` is below the current window. Returns the number of rows
  reclaimed. Runs on a timer; also callable directly in tests.

  `opts` may override `:window_ms` so the "current" window is computed against
  the same window length the rows were minted with.
  """
  def sweep_expired(opts \\ []) do
    window_ms = Keyword.get(opts, :window_ms, config(:window_ms, @default_window_ms))
    current_window = div(System.system_time(:millisecond), window_ms)

    # Object shape is {{token_id, window_index}, count}; bind the window_index
    # (2nd element of the key) and delete rows strictly older than the current
    # window. Strict `<` never touches a live current-window counter.
    :ets.select_delete(@table, [
      {{{:_, :"$1"}, :_}, [{:<, :"$1", current_window}], [true]}
    ])
  end

  @doc "Clear all counters. For tests that need a clean window."
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  # --- GenServer -------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep_expired()
    schedule_sweep()
    {:noreply, state}
  end

  # --- Internal --------------------------------------------------------------

  defp schedule_sweep do
    Process.send_after(self(), :sweep, config(:sweep_ms, @default_sweep_ms))
  end

  defp config(key, default) do
    :doit
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end

  defp ceil_div(numerator, denominator), do: div(numerator + denominator - 1, denominator)
end
