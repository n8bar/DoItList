defmodule DoitMcp.ImportGate.Counter do
  @moduledoc """
  Per-session memory for the confirms the operator granted — import targets,
  and the progress-calc gate's key (`{:progress_calc, id, requested}`, fix
  17). Pressure decays, sanction persists (m03.04 3.1 iteration 2):
  task-creation PRESSURE comes from the database's `inserted_at` window
  (`DoitMcp.ImportPressure`) and is deliberately shared across connections,
  so this process holds only what the operator said yes to.

  Rows key on the SESSION process (m03.04 item 23.6). Under stdio that was
  free — one session per OS process — but the resident HTTP transport serves
  every connected client from one VM, where a flat set would settle an
  Initiative for sessions that answered nothing. The key is
  `DoitMcp.RequestSession`'s session pid, installed on every transport, so
  one mechanism is correct on both: stdio's single session reproduces its
  old per-VM semantics exactly. Each keyed session is monitored and its row
  dies with it — nothing survives a session, and a VM outliving thousands of
  them holds no trace. A caller outside any request task (a unit test
  driving a tool directly) gets one `:unscoped` row, which no session can
  see and no session can reach.

  Keys within a row are the same `t:DoitMcp.ImportGate.target/0` refs the
  gate evaluates. Every function degrades gracefully — false / no-op / empty
  — when the process isn't running (unit tests exercise tools without it).
  """

  use GenServer

  alias DoitMcp.RequestSession

  # The row for callers with no session — see the moduledoc. One row for the
  # VM's lifetime; on stdio that IS the session.
  @unscoped :unscoped

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, name()))
  end

  @doc """
  The registered name this module talks to. Overridable via the
  `:import_gate_counter` app env for tests.
  """
  def name do
    Application.get_env(:doit_mcp, :import_gate_counter, __MODULE__)
  end

  @doc """
  Remember a confirm the operator granted this session — an import target,
  or one of the other gates' keys.
  """
  @spec mark_confirmed(term()) :: :ok
  def mark_confirmed(target), do: call({:mark_confirmed, session_key(), target}, :ok)

  @doc "Whether the operator already granted this confirm on THIS session."
  @spec confirmed?(term()) :: boolean()
  def confirmed?(target), do: call({:confirmed?, session_key(), target}, false)

  @doc "The sessions currently holding confirms (tests, diagnostics)."
  @spec sessions() :: [pid() | :unscoped]
  def sessions, do: call(:sessions, [])

  defp call(message, default) do
    case GenServer.whereis(name()) do
      nil -> default
      server -> GenServer.call(server, message)
    end
  end

  defp session_key, do: RequestSession.pid() || @unscoped

  @impl GenServer
  def init(:ok) do
    {:ok, %{rows: %{}, monitors: %{}}}
  end

  @impl GenServer
  def handle_call({:mark_confirmed, session, target}, _from, state) do
    state = ensure_row(state, session)
    {:reply, :ok, update_in(state.rows[session], &MapSet.put(&1, target))}
  end

  def handle_call({:confirmed?, session, target}, _from, state) do
    case state.rows[session] do
      nil -> {:reply, false, state}
      confirmed -> {:reply, MapSet.member?(confirmed, target), state}
    end
  end

  def handle_call(:sessions, _from, state) do
    {:reply, Map.keys(state.rows), state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {session, state} = pop_in(state.monitors[ref])
    {:noreply, %{state | rows: Map.delete(state.rows, session)}}
  end

  defp ensure_row(state, session) do
    cond do
      Map.has_key?(state.rows, session) ->
        state

      is_pid(session) ->
        ref = Process.monitor(session)
        state = put_in(state.rows[session], MapSet.new())
        put_in(state.monitors[ref], session)

      true ->
        put_in(state.rows[session], MapSet.new())
    end
  end
end
