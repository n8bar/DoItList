defmodule DoitMcp.TokenRecovery.Sessions do
  @moduledoc """
  Per-session token-recovery state for the HTTP transport (m03.04 item
  23.3): the in-memory override a successful refresh installed, the failed
  latch, and the verify-in-flight guard — each keyed by the session PROCESS,
  so one session's recovery can never bleed into another's. Nothing here is
  ever persisted anywhere; every row dies with its session (each keyed pid
  is monitored, a DOWN clears its row), and the verify guard dies with its
  verifier — a killed request task can never wedge a session's recovery
  (m03.04 2.3.2).
  """

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The session's override token, if a recovery installed one."
  @spec override(pid()) :: {:ok, String.t()} | :none
  def override(session) do
    GenServer.call(__MODULE__, {:override, session})
  end

  @doc "Install the session's override token (never persisted, never global)."
  @spec put_override(pid(), String.t()) :: :ok
  def put_override(session, token) do
    GenServer.call(__MODULE__, {:put_override, session, token})
  end

  @doc "Whether this session's recovery already failed (declined/rejected latch)."
  @spec failed?(pid()) :: boolean()
  def failed?(session) do
    GenServer.call(__MODULE__, {:failed?, session})
  end

  @doc "Latch this session failed — later 401s go straight to guidance."
  @spec mark_failed(pid()) :: :ok
  def mark_failed(session) do
    GenServer.call(__MODULE__, {:mark_failed, session})
  end

  @doc "Whether a freshly accepted token's verify retry is in flight on this session."
  @spec verifying?(pid()) :: boolean()
  def verifying?(session) do
    GenServer.call(__MODULE__, {:verifying?, session})
  end

  @doc """
  Raise the verify-in-flight guard with the CALLER as verifier. A guard
  already up stays up — already-guarded is the correct reading.
  """
  @spec begin_verify(pid()) :: :ok
  def begin_verify(session) do
    GenServer.call(__MODULE__, {:begin_verify, session, self()})
  end

  @doc """
  Drop the verify guard — holder-only: a joiner concluding its own retry
  leaves the verifier's guard alone, and a verifier killed outright needs no
  call at all (its monitor clears the guard).
  """
  @spec conclude_verify(pid()) :: :ok
  def conclude_verify(session) do
    GenServer.call(__MODULE__, {:conclude_verify, session, self()})
  end

  @impl GenServer
  def init(:ok) do
    {:ok, %{rows: %{}, monitors: %{}}}
  end

  @impl GenServer
  def handle_call({:override, session}, _from, state) do
    case get_in(state.rows, [session, Access.key(:override)]) do
      nil -> {:reply, :none, state}
      token -> {:reply, {:ok, token}, state}
    end
  end

  def handle_call({:put_override, session, token}, _from, state) do
    state = ensure_row(state, session)
    {:reply, :ok, put_in(state.rows[session].override, token)}
  end

  def handle_call({:failed?, session}, _from, state) do
    {:reply, match?(%{failed: true}, state.rows[session]), state}
  end

  def handle_call({:mark_failed, session}, _from, state) do
    state = ensure_row(state, session)
    {:reply, :ok, put_in(state.rows[session].failed, true)}
  end

  def handle_call({:verifying?, session}, _from, state) do
    {:reply, get_in(state.rows, [session, Access.key(:verifier)]) != nil, state}
  end

  def handle_call({:begin_verify, session, verifier}, _from, state) do
    state = ensure_row(state, session)

    case state.rows[session].verifier do
      nil ->
        ref = Process.monitor(verifier)
        state = put_in(state.rows[session].verifier, verifier)
        {:reply, :ok, put_in(state.monitors[ref], {:verifier, session, verifier})}

      _already_guarded ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:conclude_verify, session, caller}, _from, state) do
    case state.rows[session] do
      %{verifier: ^caller} -> {:reply, :ok, put_in(state.rows[session].verifier, nil)}
      _other_or_none -> {:reply, :ok, state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {tag, state} = pop_in(state.monitors[ref])

    state =
      case tag do
        {:session, session} ->
          %{state | rows: Map.delete(state.rows, session)}

        {:verifier, session, verifier} ->
          case state.rows[session] do
            %{verifier: ^verifier} -> put_in(state.rows[session].verifier, nil)
            _other_or_none -> state
          end

        nil ->
          state
      end

    {:noreply, state}
  end

  defp ensure_row(state, session) do
    if Map.has_key?(state.rows, session) do
      state
    else
      ref = Process.monitor(session)
      state = put_in(state.rows[session], %{override: nil, failed: false, verifier: nil})
      put_in(state.monitors[ref], {:session, session})
    end
  end
end
