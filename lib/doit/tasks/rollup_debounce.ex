defmodule DoIt.Tasks.RollupDebounce do
  @moduledoc """
  Per-Initiative debounce for ancestor roll-up recomputes (m03.02 item 4).

  Why: the m03.02 item 5.2 benchmark showed 150 concurrent writers to ONE
  Initiative failing 93% of their writes — every write transaction recomputed
  and re-wrote the same shared ancestor rows (ultimately the Initiative's
  root), serializing the whole herd on row locks until the pool checkout
  clock ran out. The same load split across separate Initiatives failed only
  6%: the shared root was the bottleneck, not pool math.

  So in `:async` mode (`config :doit, :rollup_recompute` — item 4.7) a write
  commits only its OWN row's progress synchronously and hands the ancestor
  chain to this module: one process per Initiative with pending work, keyed
  in a `Registry`, holding the set of dirty seed task ids. After a quiet
  `debounce_ms` — but never longer than `max_wait_ms` past the window's first
  enqueue, so a continuously-busy tree still flushes — it runs ONE recompute
  pass over all dirty seeds (`DoIt.Tasks.run_rollup_pass/2`, which also
  broadcasts the ancestors that actually changed) and stops. A single
  serialized writer per Initiative replaces N concurrent transactions
  fighting over one root row. Both windows are retunable:

      config :doit, DoIt.Tasks.RollupDebounce, debounce_ms: 150, max_wait_ms: 500

  Lifecycle is deliberately disposable:

    * started on demand by `enqueue/2` (`DynamicSupervisor` + `{:via,
      Registry, ...}`), `restart: :temporary`;
    * stops normally right after its flush — no idle processes linger;
    * a crash mid-window just drops that window's seed set (item 4.6):
      `computed_progress` is recomputed from CURRENT row state on every
      pass, so the next edit anywhere near the chain self-heals the values —
      no periodic sweep, no persisted queue.

  `enqueue/2` uses a call, not a cast: a cast to a process that already
  flushed and is stopping would vanish silently, losing the seed. The call
  either lands the seed in state before any later flush, or exits — and the
  exit is caught and retried against a fresh process (bounded attempts; the
  dead pid's Registry entry can outlive it for a beat).
  """

  use GenServer, restart: :temporary

  require Logger

  @registry DoIt.Tasks.RollupDebounce.Registry
  @supervisor DoIt.Tasks.RollupDebounce.Supervisor

  # Recommended defaults (see moduledoc for the config override).
  @default_debounce_ms 150
  @default_max_wait_ms 500

  # Bounded retry for the stopping-process race in enqueue/2.
  @enqueue_attempts 5
  @retry_pause_ms 10

  @doc "Registry name — an `application.ex` child (`keys: :unique`)."
  def registry, do: @registry

  @doc "DynamicSupervisor name — an `application.ex` child."
  def supervisor, do: @supervisor

  @doc """
  Mark `seed_task_id`'s ancestor chain dirty for `initiative_id`, starting the
  Initiative's debounce process if none is running. Called post-commit only
  (`DoIt.Tasks` queues it through `DoIt.Broadcast.after_commit/1`), so the
  eventual pass never reads pre-commit state.
  """
  def enqueue(initiative_id, seed_task_id) do
    enqueue_attempt(initiative_id, seed_task_id, @enqueue_attempts)
  end

  defp enqueue_attempt(initiative_id, seed_task_id, 0) do
    # Every attempt raced a stopping/dying process. Dropping the seed is the
    # same accepted gap as a crash mid-window: stale until the next edit,
    # which self-heals the chain. Loud so a systemic problem can't hide.
    Logger.warning(
      "RollupDebounce.enqueue gave up after racing stopping processes " <>
        "(initiative #{initiative_id}, seed #{seed_task_id})"
    )

    :error
  end

  defp enqueue_attempt(initiative_id, seed_task_id, attempts) do
    pid =
      case DynamicSupervisor.start_child(@supervisor, {__MODULE__, initiative_id}) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    try do
      GenServer.call(pid, {:enqueue, seed_task_id})
    catch
      :exit, _ ->
        # The process flushed/stopped (or crashed) between lookup and call.
        # Pause a beat so the Registry can unregister the dead pid, then
        # start fresh.
        Process.sleep(@retry_pause_ms)
        enqueue_attempt(initiative_id, seed_task_id, attempts - 1)
    end
  end

  @doc "The pid currently debouncing `initiative_id`, or `nil`. Test introspection."
  def whereis(initiative_id) do
    case Registry.lookup(@registry, initiative_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def start_link(initiative_id) do
    GenServer.start_link(__MODULE__, initiative_id,
      name: {:via, Registry, {@registry, initiative_id}}
    )
  end

  @impl true
  def init(initiative_id) do
    opts = Application.get_env(:doit, __MODULE__, [])

    {:ok,
     %{
       initiative_id: initiative_id,
       seeds: MapSet.new(),
       timer: nil,
       first_enqueue_at: nil,
       debounce_ms: Keyword.get(opts, :debounce_ms, @default_debounce_ms),
       max_wait_ms: Keyword.get(opts, :max_wait_ms, @default_max_wait_ms)
     }}
  end

  @impl true
  def handle_call({:enqueue, seed_task_id}, _from, state) do
    now = System.monotonic_time(:millisecond)
    first_at = state.first_enqueue_at || now
    if state.timer, do: Process.cancel_timer(state.timer)

    # Quiet-period debounce with a hard bound: flush after debounce_ms of
    # silence, or max_wait_ms after the window's first enqueue — whichever
    # comes first.
    delay = min(state.debounce_ms, max(first_at + state.max_wait_ms - now, 0))

    {:reply, :ok,
     %{
       state
       | seeds: MapSet.put(state.seeds, seed_task_id),
         timer: Process.send_after(self(), :flush, delay),
         first_enqueue_at: first_at
     }}
  end

  @impl true
  def handle_info(:flush, state) do
    DoIt.Tasks.run_rollup_pass(state.initiative_id, MapSet.to_list(state.seeds))

    # One-shot: flush, then stop (terminates when idle). The next edit starts
    # a fresh process; an enqueue racing this stop retries (see enqueue/2).
    {:stop, :normal, state}
  end
end
