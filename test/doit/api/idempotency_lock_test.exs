defmodule DoIt.Api.IdempotencyLockTest do
  @moduledoc """
  Mutual exclusion for `Idempotency.with_key_lock/3` (m03.04 2.19).

  Each task starts its OWN sandbox owner, so the two lock calls contend on two
  real Postgres sessions — on the usual shared sandbox connection the advisory
  lock would be reentrant and the test would prove nothing. `async: false`
  because the module flips the sandbox to manual mode.
  """
  use ExUnit.Case, async: false

  alias DoIt.Accounts.User
  alias DoIt.Api.Idempotency
  alias DoIt.Repo
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(Repo, :manual)
    :ok
  end

  # Runs `with_key_lock` on its own sandbox connection, reporting :entered /
  # :exited to the test and holding the lock until told to :release.
  defp locked_task(user, key, parent, tag) do
    Task.async(fn ->
      owner = Sandbox.start_owner!(Repo)

      try do
        Idempotency.with_key_lock(user, key, fn ->
          send(parent, {tag, :entered, System.monotonic_time()})

          receive do
            :release -> :ok
          after
            10_000 -> raise "never released"
          end

          send(parent, {tag, :exited, System.monotonic_time()})
        end)
      after
        Sandbox.stop_owner(owner)
      end
    end)
  end

  test "same (user, key): the second caller waits until the first is done" do
    user = %User{id: 424_242}
    key = "race-#{System.unique_integer([:positive])}"

    a = locked_task(user, key, self(), :a)
    assert_receive {:a, :entered, _}, 5_000

    b = locked_task(user, key, self(), :b)
    # B must sit blocked on the lock while A holds it.
    refute_receive {:b, :entered, _}, 300

    send(a.pid, :release)
    assert_receive {:a, :exited, a_exited}, 5_000
    assert_receive {:b, :entered, b_entered}, 5_000
    assert b_entered >= a_exited

    send(b.pid, :release)
    assert_receive {:b, :exited, _}, 5_000
    Task.await(a)
    Task.await(b)
  end

  test "different keys don't contend" do
    user = %User{id: 424_242}
    n = System.unique_integer([:positive])

    a = locked_task(user, "one-#{n}", self(), :a)
    assert_receive {:a, :entered, _}, 5_000

    b = locked_task(user, "two-#{n}", self(), :b)
    assert_receive {:b, :entered, _}, 5_000

    send(a.pid, :release)
    send(b.pid, :release)
    Task.await(a)
    Task.await(b)
  end

  test "returns the fun's value and releases the lock for the next caller" do
    user = %User{id: 424_242}
    key = "reuse-#{System.unique_integer([:positive])}"
    owner = Sandbox.start_owner!(Repo)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    assert Idempotency.with_key_lock(user, key, fn -> :value end) == :value
    # A second acquisition on the same session succeeds only if the first
    # released; a fresh session then contends normally (covered above).
    assert Idempotency.with_key_lock(user, key, fn -> :again end) == :again
  end
end
