defmodule DoitMcp.ImportGateCounterTest do
  # async: false — the counter answers under a name the whole VM shares
  # (the :import_gate_counter app env).
  use ExUnit.Case, async: false

  alias DoitMcp.ImportGate.Counter

  # The gate's confirm memory keys on the SESSION (m03.04 item 23.6): the
  # resident HTTP VM serves every connected client at once, so a flat set
  # would settle an Initiative for sessions that never answered anything.
  # Each keyed session is monitored and its row dies with it.

  setup do
    name = :"#{__MODULE__}.Counter"
    start_supervised!({Counter, name: name})

    previous = Application.fetch_env(:doit_mcp, :import_gate_counter)
    Application.put_env(:doit_mcp, :import_gate_counter, name)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:doit_mcp, :import_gate_counter, value)
        :error -> Application.delete_env(:doit_mcp, :import_gate_counter)
      end
    end)

    :ok
  end

  # A stand-in session process — the counter keys on its identity, so
  # nothing but liveness matters. Deliberately unsupervised: these get
  # killed on purpose.
  defp session do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp stop(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
  end

  # Run `fun` the way one of the session's request tasks would: Anubis
  # starts every request under the session's Task.Supervisor, so the session
  # heads the task's $callers chain — which is what DoitMcp.RequestSession
  # installs. The task then dies, as a served request does; the row belongs
  # to the session, not the caller.
  defp as_session(session, fun) do
    Task.async(fn ->
      Process.put(:"$callers", [session])
      DoitMcp.RequestSession.install(%{context: %{session_id: "session-#{inspect(session)}"}})
      fun.()
    end)
    |> Task.await(1_000)
  end

  test "a confirm belongs to the session that granted it" do
    a = session()
    b = session()

    as_session(a, fn -> Counter.mark_confirmed({:existing, 57}) end)

    assert as_session(a, fn -> Counter.confirmed?({:existing, 57}) end)
    refute as_session(b, fn -> Counter.confirmed?({:existing, 57}) end)
    # And no session at all (a unit test driving a tool directly) is its own
    # row — never the grantor's.
    refute Counter.confirmed?({:existing, 57})

    stop(a)
    stop(b)
  end

  test "a session's confirms die with it" do
    a = session()

    as_session(a, fn -> Counter.mark_confirmed({:existing, 57}) end)
    assert a in Counter.sessions()

    stop(a)

    # The counter's DOWN was queued at the exit, ahead of this call.
    refute a in Counter.sessions()
  end

  test "a VM outliving many sessions keeps none of them" do
    for _ <- 1..50 do
      s = session()
      as_session(s, fn -> Counter.mark_confirmed({:existing, 57}) end)
      stop(s)
    end

    assert Counter.sessions() == []
  end

  test "a caller outside any request task keeps its own row" do
    Counter.mark_confirmed({:existing, 57})
    assert Counter.confirmed?({:existing, 57})

    a = session()
    refute as_session(a, fn -> Counter.confirmed?({:existing, 57}) end)
    stop(a)
  end

  test "every function degrades gracefully with no counter running" do
    Application.put_env(:doit_mcp, :import_gate_counter, :"#{__MODULE__}.Absent")

    assert Counter.mark_confirmed({:existing, 57}) == :ok
    refute Counter.confirmed?({:existing, 57})
    assert Counter.sessions() == []
  end
end
