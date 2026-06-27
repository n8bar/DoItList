defmodule DoIt.Api.RateLimiterTest do
  @moduledoc """
  The ETS-backed per-token sliding-window limiter (m03.01 worklist 1.5). Driven
  directly with `:limit` / `:window_ms` / `:now_ms` overrides so the cap, the
  window boundary, and the retry hint are deterministic without touching config
  or sleeping.
  """
  use ExUnit.Case, async: true

  alias DoIt.Api.RateLimiter

  # A token id unique to each test, so counters never bleed between tests
  # sharing the process-wide ETS table.
  defp token_id, do: System.unique_integer([:positive])

  test "allows up to the limit, then rejects with a retry hint" do
    id = token_id()
    opts = [limit: 3, window_ms: 60_000]

    assert RateLimiter.check_rate(id, opts) == :ok
    assert RateLimiter.check_rate(id, opts) == :ok
    assert RateLimiter.check_rate(id, opts) == :ok

    assert {:error, retry_after} = RateLimiter.check_rate(id, opts)
    assert is_integer(retry_after)
    assert retry_after > 0
    assert retry_after <= 60
  end

  test "different tokens have independent budgets" do
    a = token_id()
    b = token_id()
    opts = [limit: 1, window_ms: 60_000]

    assert RateLimiter.check_rate(a, opts) == :ok
    assert {:error, _} = RateLimiter.check_rate(a, opts)

    # b is untouched by a's exhaustion.
    assert RateLimiter.check_rate(b, opts) == :ok
  end

  test "a fresh window allows requests again once the prior window has aged out" do
    id = token_id()

    # window_ms: 1 means each millisecond is its own window. Sleeping 2ms moves
    # two windows on, so the immediately-previous window (the only one the
    # sliding estimate still weighs) is empty and the request is allowed again.
    assert RateLimiter.check_rate(id, limit: 1, window_ms: 1) == :ok
    Process.sleep(2)
    assert RateLimiter.check_rate(id, limit: 1, window_ms: 1) == :ok
  end

  # This is the case the in-process ConnTest cannot observe: it fires its whole
  # burst inside one wall-clock-aligned window, so a plain FIXED window passes it
  # too. The live limiter saw a slow/straddling burst reset at the :00 boundary
  # and never throttle. The sliding window keeps the previous window's history,
  # so crossing a boundary does NOT hand back a fresh budget.
  test "crossing a window boundary does not reset the cap (sliding, not fixed)" do
    id = token_id()
    window_ms = 60_000
    limit = 5

    # Anchor on the real current window so the background sweep (which reclaims
    # rows older than current-1) can't delete the buckets mid-test.
    w = div(System.system_time(:millisecond), window_ms)
    near_end = w * window_ms + window_ms - 1
    just_after = (w + 1) * window_ms + 1

    # Saturate window w (at its tail); the cap+1 request is rejected.
    for _ <- 1..limit do
      assert RateLimiter.check_rate(id, limit: limit, window_ms: window_ms, now_ms: near_end) ==
               :ok
    end

    assert {:error, _} =
             RateLimiter.check_rate(id, limit: limit, window_ms: window_ms, now_ms: near_end)

    # First request just past the boundary: a fixed window would allow it (fresh
    # counter); the sliding window still weighs window w at ~full and rejects.
    assert {:error, retry} =
             RateLimiter.check_rate(id, limit: limit, window_ms: window_ms, now_ms: just_after)

    assert retry > 0
  end

  test "a missing metering table raises instead of silently allowing traffic" do
    # A not-started/named-wrong table must NOT fail open (return :ok). Drive
    # check_rate at a table that doesn't exist and assert it raises a clear
    # wiring error rather than waving the request through.
    assert_raise RuntimeError, ~r/is absent/, fn ->
      RateLimiter.check_rate(token_id(), limit: 1, table: :doit_rate_limit_missing_table)
    end
  end

  test "sweep_expired/1 reclaims elapsed-window rows but keeps live ones" do
    table = :doit_api_rate_limit
    window_ms = 60_000
    id = token_id()

    # Window indices 1 and 2 are unconditionally far below the current window
    # (~2.9e7 for 60s windows), so they're always "elapsed". A far-future index
    # is never below the current window, so it stands in for a live counter.
    # Fixed indices keep the assertion free of any wall-clock boundary race.
    future = div(System.system_time(:millisecond), window_ms) + 1_000_000
    :ets.insert(table, {{id, 1}, 9})
    :ets.insert(table, {{id, 2}, 9})
    :ets.insert(table, {{id, future}, 9})

    deleted = RateLimiter.sweep_expired(window_ms: window_ms)

    # The two elapsed windows for this token are gone; the live one survives.
    assert deleted >= 2
    assert :ets.lookup(table, {id, 1}) == []
    assert :ets.lookup(table, {id, 2}) == []
    refute :ets.lookup(table, {id, future}) == []
  end
end
