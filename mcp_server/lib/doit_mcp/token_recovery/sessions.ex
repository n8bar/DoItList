defmodule DoitMcp.TokenRecovery.Sessions do
  @moduledoc """
  Per-session token-recovery state for the HTTP transport (m03.04 item
  23.3): the in-memory override a paste installed, whether a call has proved
  it yet, and the failed latch — each keyed by the session PROCESS, so one
  session's recovery can never bleed into another's. Nothing here is ever
  persisted anywhere; every row dies with its session (each keyed pid is
  monitored, a DOWN clears its row).

  An override lands UNVERIFIED (m03.04 2.3.3): the session's next API call
  proves it — a non-401 answer marks it verified, a 401 latches the session
  and drops it — and until then every 401 on that session reuses it instead
  of raising another form (the join, m03.04 2.3.2). The state is a flag, not
  a holding process, so a killed request task can never wedge a session's
  recovery: the next call simply proves the paste again.
  """

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The session's override token, if a paste installed one, and whether a call has proved it."
  @spec override(pid()) :: {:verified, String.t()} | {:unverified, String.t()} | :none
  def override(session) do
    GenServer.call(__MODULE__, {:override, session})
  end

  @doc "Install the session's override token, unverified (never persisted, never global)."
  @spec put_override(pid(), String.t()) :: :ok
  def put_override(session, token) do
    GenServer.call(__MODULE__, {:put_override, session, token})
  end

  @doc "The override's first non-401 answer: it is this session's proven credential now."
  @spec mark_verified(pid()) :: :ok
  def mark_verified(session) do
    GenServer.call(__MODULE__, {:mark_verified, session})
  end

  @doc "Whether this session's recovery already failed (declined/rejected latch)."
  @spec failed?(pid()) :: boolean()
  def failed?(session) do
    GenServer.call(__MODULE__, {:failed?, session})
  end

  @doc """
  Latch this session failed and drop any override — later 401s go straight
  to guidance, on the header token the session presents.
  """
  @spec mark_failed(pid()) :: :ok
  def mark_failed(session) do
    GenServer.call(__MODULE__, {:mark_failed, session})
  end

  @impl GenServer
  def init(:ok) do
    {:ok, %{rows: %{}, monitors: %{}}}
  end

  @impl GenServer
  def handle_call({:override, session}, _from, state) do
    case state.rows[session] do
      %{override: token, verified: true} when is_binary(token) ->
        {:reply, {:verified, token}, state}

      %{override: token} when is_binary(token) ->
        {:reply, {:unverified, token}, state}

      _none ->
        {:reply, :none, state}
    end
  end

  def handle_call({:put_override, session, token}, _from, state) do
    state = ensure_row(state, session)
    row = %{state.rows[session] | override: token, verified: false}
    {:reply, :ok, put_in(state.rows[session], row)}
  end

  def handle_call({:mark_verified, session}, _from, state) do
    case state.rows[session] do
      %{override: token} when is_binary(token) ->
        {:reply, :ok, put_in(state.rows[session].verified, true)}

      _no_override ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:failed?, session}, _from, state) do
    {:reply, match?(%{failed: true}, state.rows[session]), state}
  end

  def handle_call({:mark_failed, session}, _from, state) do
    state = ensure_row(state, session)
    row = %{state.rows[session] | failed: true, override: nil, verified: false}
    {:reply, :ok, put_in(state.rows[session], row)}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {tag, state} = pop_in(state.monitors[ref])

    state =
      case tag do
        {:session, session} -> %{state | rows: Map.delete(state.rows, session)}
        nil -> state
      end

    {:noreply, state}
  end

  defp ensure_row(state, session) do
    if Map.has_key?(state.rows, session) do
      state
    else
      ref = Process.monitor(session)
      state = put_in(state.rows[session], %{override: nil, verified: false, failed: false})
      put_in(state.monitors[ref], {:session, session})
    end
  end
end
