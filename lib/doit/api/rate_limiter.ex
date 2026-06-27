defmodule DoIt.Api.RateLimiter do
  @moduledoc """
  Per-token sliding-window rate limiter for the HTTP API (m03.01 worklist 1.5).

  A tiny GenServer owns a named public ETS table; the hot path
  (`check_rate/2`) is a lock-free `:ets.update_counter/4`, so it doesn't funnel
  every request through the GenServer. No new dependency.

  ## Window model

  Sliding window, approximated with two fixed buckets (the standard
  "sliding-window counter"). Each bucket is keyed `{token_id, window_index}`
  where `window_index = div(now_ms, window_ms)`; only the *current* bucket is
  ever incremented. A request's effective count is the current bucket's exact
  value plus the *previous* bucket weighted by the fraction of it still inside
  the trailing `window_ms`:

      estimated = current + previous * (window_ms - elapsed_in_window) / window_ms

  As wall-clock time advances through the current window the previous bucket's
  contribution decays linearly to zero. When `estimated` exceeds the limit the
  request is rejected with a `Retry-After` hint (seconds until the window
  rolls).

  This is what makes the cap hold over **any** rolling `window_ms`, not just the
  wall-clock-aligned one. A plain fixed window resets its counter at every `:00`
  boundary, so a client pacing its traffic across that boundary — or simply a
  slow sequential burst that happens to straddle it — never accumulates `limit`
  within a single aligned window and is never throttled (the boundary "2× limit"
  burst is the mild version of the same hole). The two-bucket estimate closes
  that: history from the previous window still counts, proportionally, so the
  burst trips at ~`limit` regardless of where the boundary falls. The estimate
  is an approximation (it assumes the previous window's requests were spread
  evenly), which is fine for a coarse abuse cap, and it stays lock-free — one
  `:ets.update_counter/4` plus one plain read.

  ## Reclaiming stale windows

  Each `{token_id, window_index}` counter belongs to exactly one window. The hot
  path reads the current and the immediately preceding window, so a bucket is
  dead weight only once it is **two** windows back. Left alone the table would
  grow one row per token per window forever. A periodic sweep
  (`handle_info(:sweep, …)`, every `sweep_ms`) reclaims it:
  `:ets.select_delete/2` removes every row whose `window_index` is below
  `current_window - 1`, so the table stays proportional to *active* tokens, not
  to elapsed time. `sweep_expired/1` is also callable directly (tests).

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

  Returns `:ok`, or `{:error, retry_after_seconds}` when the rolling-window limit
  is exceeded. `opts` may override (all for direct unit tests):

    * `:limit` / `:window_ms` — the cap and window length (defaults from config);
    * `:now_ms` — the reference instant, so a test can place a request at a
      precise point relative to a window boundary without sleeping;
    * `:table` — the ETS table to meter against (defaults to the live one).

  If the metering table is absent (the limiter GenServer never started) this
  **raises** rather than returning `:ok`: a missing table must not silently
  disable the cap. The table is rebuilt empty only on a GenServer *restart*
  (which fails open by design — see the moduledoc); never-started is a wiring
  bug and is surfaced loudly.
  """
  def check_rate(token_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, config(:limit, @default_limit))
    window_ms = Keyword.get(opts, :window_ms, config(:window_ms, @default_window_ms))
    table = Keyword.get(opts, :table, @table)
    now_ms = Keyword.get(opts, :now_ms, System.system_time(:millisecond))

    window_index = div(now_ms, window_ms)
    cur_key = {token_id, window_index}
    prev_key = {token_id, window_index - 1}

    # Count this request in the current window (lock-free; creates the row on
    # first touch). Rejected requests still increment — a flood keeps the
    # estimate pinned over the limit until it ages out, which is the point.
    cur = increment(table, cur_key)

    # Sliding window: weight the PREVIOUS window by the fraction of it still
    # inside the trailing `window_ms`, and add the current window's exact count.
    # As wall-clock time advances through the current window the previous
    # window's contribution decays linearly to zero. This makes the cap hold
    # over ANY rolling `window_ms` — a burst that straddles a window boundary
    # can't shed its history by resetting the counter at the boundary, the way a
    # plain fixed window does.
    prev = bucket_count(table, prev_key)
    elapsed_in_window = now_ms - window_index * window_ms
    prev_weight = (window_ms - elapsed_in_window) / window_ms
    estimated = cur + prev * prev_weight

    if estimated <= limit do
      :ok
    else
      # Coarse hint: try again once the window rolls (the previous window has
      # fully aged out by then). Bounded to [1, window_ms] seconds.
      window_end = (window_index + 1) * window_ms
      retry_after = max(1, ceil_div(window_end - now_ms, 1000))
      {:error, retry_after}
    end
  end

  # Increment (creating on first touch) the current-window counter. A missing
  # table makes `:ets.update_counter/4` raise ArgumentError; re-raise it as a
  # clear wiring error so the limiter never silently fails OPEN on a not-started
  # table (the symptom an operator sees as "no limiting at all").
  defp increment(table, key) do
    :ets.update_counter(table, key, {2, 1}, {key, 0})
  rescue
    ArgumentError ->
      reraise(
        "DoIt.Api.RateLimiter ETS table #{inspect(table)} is absent — the limiter " <>
          "GenServer is not running. Refusing to silently allow unlimited traffic.",
        __STACKTRACE__
      )
  end

  # Current value of a `{token_id, window_index}` counter, or 0 if absent. A
  # plain read (no increment) — only the current window is ever incremented.
  defp bucket_count(table, key) do
    case :ets.lookup(table, key) do
      [{^key, n}] -> n
      [] -> 0
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
    # (2nd element of the key) and delete rows older than the PREVIOUS window.
    # The sliding-window estimate reads both the current and the immediately
    # preceding window, so only rows two or more windows back are dead weight —
    # `< current_window - 1` never touches either live counter.
    :ets.select_delete(@table, [
      {{{:_, :"$1"}, :_}, [{:<, :"$1", current_window - 1}], [true]}
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
