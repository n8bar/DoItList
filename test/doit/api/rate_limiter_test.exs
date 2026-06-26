defmodule DoIt.Api.RateLimiterTest do
  @moduledoc """
  The ETS-backed per-token fixed-window limiter (m03.01 worklist 1.5). Driven
  directly with `:limit` / `:window_ms` overrides so the cap and retry hint are
  deterministic without touching config.
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

  test "a fresh window allows requests again" do
    id = token_id()

    # window_ms: 1 means each millisecond is its own window, so a later call
    # almost always lands in a new window with a fresh counter.
    assert RateLimiter.check_rate(id, limit: 1, window_ms: 1) == :ok
    Process.sleep(2)
    assert RateLimiter.check_rate(id, limit: 1, window_ms: 1) == :ok
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
