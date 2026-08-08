defmodule DoitMcp.ImportGate.PendingConfirm do
  @moduledoc """
  Per-session memory for the import confirm currently awaiting the operator
  (m03.04 item 27.1): a gated `apply_operations` no longer waits on its
  confirm — it returns the readback and leaves the form out-of-band — so the
  fact that a readback went out, and any decision the form brought back,
  must outlive the tool call. One row per session (Anubis serializes
  elicitations per session anyway), keyed like `DoitMcp.ImportGate.Counter`:
  the session process, monitored, the row dying with it; `:unscoped` for
  callers outside any request task. The ROW never expires on its own — only
  the form's waiter does — so the in-app confirm (m03.04 item 30) still
  resolves a long-abandoned form.

  A row is `{key, form}` — `key` binds the confirm to the exact batch read
  back (the operations hash); `form` is `:waiting`, or `{:answered, outcome}`
  holding a form decision (decline/correct/hold) until a re-call picks it up
  (a form APPROVAL marks the Counter instead and clears the row). First
  answer wins: `claim/1` (the in-app consult) and `form_answered/2` (the
  form) serialize through this process, and the loser reads the row's new
  state.

  Every function degrades gracefully — `:none` / no-op — when the process
  isn't running, Counter's precedent.
  """

  use GenServer

  alias DoitMcp.RequestSession

  # The row for callers with no session — Counter's precedent.
  @unscoped :unscoped

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, name()))
  end

  @doc """
  The registered name this module talks to. Overridable via the
  `:import_gate_pending_confirm` app env for tests.
  """
  def name do
    Application.get_env(:doit_mcp, :import_gate_pending_confirm, __MODULE__)
  end

  @doc """
  Record this session's pending confirm — a readback went out for `key`.
  Overwrites any stale row (the agent moved on to a different batch).
  """
  @spec open(term()) :: :ok
  def open(key), do: call({:open, session_key(), key}, :ok)

  @doc """
  Consume the pending confirm for `key` — the in-app consult's claim, or
  the form-approval's. `:pending` means the caller's decision wins (row
  deleted); `{:answered, outcome}` means the form already decided (row
  deleted, first answer wins); `:none` means nothing was pending for this
  batch on this session.
  """
  @spec claim(term()) :: :none | :pending | {:answered, map()}
  def claim(key), do: call({:claim, session_key(), key}, :none)

  @doc """
  Pick up a form decision awaiting delivery for `key`, if any — the plain
  re-call's read. Consumes only an `{:answered, outcome}` row; a `:waiting`
  row stands.
  """
  @spec take_answered(term()) :: :none | {:answered, map()}
  def take_answered(key), do: call({:take_answered, session_key(), key}, :none)

  @doc """
  Record the form's decline/correct/hold decision for `key`. `:stale` when
  the row is gone or answered — superseded, already claimed via chat, or
  never opened — and the answer is dropped.
  """
  @spec form_answered(term(), map()) :: :ok | :stale
  def form_answered(key, outcome), do: call({:form_answered, session_key(), key, outcome}, :stale)

  defp call(message, default) do
    case GenServer.whereis(name()) do
      nil -> default
      server -> GenServer.call(server, message)
    end
  end

  defp session_key, do: RequestSession.pid() || @unscoped

  @impl GenServer
  def init(:ok) do
    {:ok, %{rows: %{}, monitors: %{}, watched: MapSet.new()}}
  end

  @impl GenServer
  def handle_call({:open, session, key}, _from, state) do
    state = watch(state, session)
    {:reply, :ok, put_in(state.rows[session], %{key: key, form: :waiting})}
  end

  def handle_call({:claim, session, key}, _from, state) do
    case state.rows[session] do
      %{key: ^key, form: form} ->
        reply = if form == :waiting, do: :pending, else: form
        {:reply, reply, %{state | rows: Map.delete(state.rows, session)}}

      _ ->
        {:reply, :none, state}
    end
  end

  def handle_call({:take_answered, session, key}, _from, state) do
    case state.rows[session] do
      %{key: ^key, form: {:answered, _outcome} = answered} ->
        {:reply, answered, %{state | rows: Map.delete(state.rows, session)}}

      _ ->
        {:reply, :none, state}
    end
  end

  def handle_call({:form_answered, session, key, outcome}, _from, state) do
    case state.rows[session] do
      %{key: ^key, form: :waiting} ->
        {:reply, :ok, put_in(state.rows[session], %{key: key, form: {:answered, outcome}})}

      _ ->
        {:reply, :stale, state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {session, state} = pop_in(state.monitors[ref])

    {:noreply,
     %{
       state
       | rows: Map.delete(state.rows, session),
         watched: MapSet.delete(state.watched, session)
     }}
  end

  # Rows come and go per session, so monitoring is tracked separately — one
  # monitor per session pid for this process's lifetime with that session.
  defp watch(state, session) do
    if is_pid(session) and not MapSet.member?(state.watched, session) do
      ref = Process.monitor(session)

      state
      |> put_in([Access.key(:monitors), ref], session)
      |> update_in([Access.key(:watched)], &MapSet.put(&1, session))
    else
      state
    end
  end
end
