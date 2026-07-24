defmodule DoitMcp.ImportGate do
  @moduledoc """
  Pure decision logic for `apply_operations`' import gate (m03.04 fix 10):
  a first big import into an Initiative gets held for the operator's readback
  confirmation instead of applying blind.

  The gate ships ARMED: `enabled?/0` — `DOITLIST_IMPORT_GATE=off` opts out;
  any other value, including unset, arms it — is `evaluate/2`'s very first,
  cheapest check, before anything is counted or fetched. (It shipped dark
  until the concurrent stdio transport landed, m03.04 item 3.11.1 — the old
  serial transport could never read the operator's answer.)

  The trigger is CUMULATIVE over a trailing time window (m03.04 items 3.11.2
  and 3.1 iteration 2): sub-cap chunking is sanctioned, so no single batch
  tells the whole story — each batch's task-adds are resolved per target
  Initiative and summed with the recent-pressure fun the caller injects
  (`DoitMcp.ImportPressure`: the database's `inserted_at` window, so a
  human-rhythm drip decays and a reconnect resets nothing). An add anchored
  on an EXISTING task's `parent_id` — the most common import shape, growing
  an existing tree — resolves through the caller-built `parent_targets` map
  (m03.04 item 2.18): the caller reads each unique parent once
  (`GET /api/v1/tasks/:id`) at the IO edge (`existing_parent_ids/1` lists
  the ids), keeping this module pure. A fresh Initiative switches keys
  mid-import — created under a lid, referenced by real id from the next
  chunk on — so a confirm granted under the lid is carried to the real id
  (`created_initiative_ids/2`). An armed gate holds the batch only when ALL
  of these hold:

    1. some Initiative's cumulative task-adds — session total plus this
       batch — cross the batch's bound: `threshold/0` normally,
       `ramp_threshold/0` for a coherent one-list batch (`coherent_unit?/1`
       — each such unit lands as one reviewable increment),
    2. the connected client advertised the `elicitation` capability in its
       initialize handshake (no capability → the gate silently steps aside —
       no other layer holds the batch), and
    3. that Initiative's import is still unsettled — the operator has not
       already confirmed one this session.

  All effectful inputs (capability, session counter, confirm memory,
  Initiative fetch) are injected as funs, so the decision stays
  unit-testable; the elicitation wiring lives in `DoitMcp.Elicitation` and
  the flow in `DoitMcp.Tools.ApplyOperations`.
  """

  @task_add_threshold 32

  # The ramp (m03.04 3.1 iteration 2, operator design): a batch that delivers
  # ONE reviewable list — every add under a single parent, at most
  # @task_add_threshold adds — earns the long leash, because each such unit
  # lands visibly in the app between batches. Anything else (bulk, mixed
  # parents, oversized) keeps the tight threshold and meets the one readback
  # confirm. Both retunable; powers of two by operator taste.
  @ramp_threshold 128

  @typedoc "The Initiative a gated batch imports into."
  @type target :: {:in_batch, String.t()} | {:existing, term()}

  @doc "Cumulative task-add count above which an import is gated."
  @spec threshold() :: pos_integer()
  def threshold, do: @task_add_threshold

  @doc "The coherent-unit leash: cumulative bound while batches stay one-list-at-a-time."
  @spec ramp_threshold() :: pos_integer()
  def ramp_threshold, do: @ramp_threshold

  @doc """
  Whether the gate is armed: on by default; `DOITLIST_IMPORT_GATE=off` in
  the adapter's environment opts out (or the `:import_gate_enabled` app-env
  override in tests).
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(
      :doit_mcp,
      :import_gate_enabled,
      System.get_env("DOITLIST_IMPORT_GATE") != "off"
    )
  end

  @doc """
  Decide whether a batch must be held for operator confirmation.

  Options:

    * `:elicitation?` — zero-arity fun; whether the client advertised the
      `elicitation` capability (required)
    * `:fetch_initiative` — 1-arity fun (`id -> {:ok, map} | {:error, term}`)
      reading an existing target Initiative (required)
    * `:cumulative` — 1-arity fun (`target -> non_neg_integer`); task-adds
      already applied to that Initiative this session (defaults to zero —
      single-batch semantics)
    * `:confirmed?` — 1-arity fun (`target -> boolean`); whether the operator
      already confirmed an import into that Initiative this session
      (defaults to false)
    * `:parent_targets` — `%{parent_id => target}` map resolving the batch's
      parent-anchored adds (`existing_parent_ids/1`) to their Initiatives,
      built by the caller at the IO edge (defaults to `%{}` — such adds
      stay uncounted)

  Checks run cheapest-first (kill switch, counts, capability, settled) and
  short-circuit, so nothing is counted while `enabled?/0` is false and the
  fetch only ever happens for an over-threshold target from an
  elicitation-capable client. Returns `:pass` or
  `{:gate, %{task_adds: n, cumulative: total, target: target}}` — `task_adds`
  is this batch's count for the gated target, `cumulative` the session total
  including it. A fetch error passes — the apply itself will surface the
  real error.
  """
  @spec evaluate([map()], keyword()) ::
          :pass
          | {:gate, %{task_adds: pos_integer(), cumulative: pos_integer(), target: target()}}
  def evaluate(operations, opts) when is_list(operations) do
    cumulative = Keyword.get(opts, :cumulative, fn _target -> 0 end)
    confirmed? = Keyword.get(opts, :confirmed?, fn _target -> false end)
    parent_targets = Keyword.get(opts, :parent_targets, %{})

    with true <- enabled?(),
         [_ | _] = candidates <- over_threshold(operations, cumulative, parent_targets),
         true <- Keyword.fetch!(opts, :elicitation?).(),
         [_ | _] = unsettled <- Enum.reject(candidates, fn {ref, _, _} -> confirmed?.(ref) end),
         {:ok, gated} <- knobless_target(unsettled, Keyword.fetch!(opts, :fetch_initiative)) do
      {ref, task_adds, total} = gated
      {:gate, %{task_adds: task_adds, cumulative: total, target: ref}}
    else
      _ -> :pass
    end
  end

  @doc "Count of task-add ops in the batch."
  @spec count_task_adds([map()]) :: non_neg_integer()
  def count_task_adds(operations), do: Enum.count(operations, &task_add?/1)

  @doc """
  Task-adds in the batch summed per target Initiative, first-seen batch
  order, resolving in-batch `parent_lid` chains like `target_refs/2` and
  parent-anchored adds through `parent_targets` — the `%{parent_id =>
  target}` map the caller resolved at the IO edge (`existing_parent_ids/1`
  lists the ids to resolve). An add whose target is still unknowable (a
  `parent_id` missing from the map, a dangling `parent_lid`) is dropped —
  the apply surfaces the real error.
  """
  @spec count_by_target([map()], %{optional(term()) => target()}) ::
          [{target(), pos_integer()}]
  def count_by_target(operations, parent_targets \\ %{}) do
    task_adds = Enum.filter(operations, &task_add?/1)

    by_lid =
      for %{"lid" => lid} = op <- task_adds, is_binary(lid), into: %{}, do: {lid, op}

    refs =
      task_adds
      |> Enum.map(&resolve_ref(&1, by_lid, parent_targets, MapSet.new()))
      |> Enum.reject(&is_nil/1)

    counts = Enum.frequencies(refs)

    refs
    |> Enum.uniq()
    |> Enum.map(&{&1, Map.fetch!(counts, &1)})
  end

  @doc """
  lid → real id for the Initiatives an applied batch created, read from the
  apply response's per-op results (each echoes the op's `"lid"` beside the
  created resource's `"data"`). Later chunks can only reference a created
  Initiative by real id, so a confirm the operator granted under the lid is
  carried to the real id — the sanction survives the lid → id switch
  (pressure needs no carrying: it lives in the database's `inserted_at`).
  An unreadable results shape maps nothing.
  """
  @spec created_initiative_ids([map()], term()) :: %{String.t() => term()}
  def created_initiative_ids(operations, results) when is_list(results) do
    lids =
      for %{"op" => "add", "type" => "initiative", "lid" => lid} <- operations,
          is_binary(lid),
          into: MapSet.new(),
          do: lid

    for %{"lid" => lid, "status" => "ok", "data" => %{"id" => id}} <- results,
        MapSet.member?(lids, lid),
        into: %{},
        do: {lid, id}
  end

  def created_initiative_ids(_operations, _results), do: %{}

  @doc """
  Resolve each task-add op to the Initiative it targets, chasing in-batch
  `parent_lid` chains (an add without its own Initiative ref inherits its
  in-batch parent's) and consulting `parent_targets` when an add — or the
  chain it hangs off — ends at an existing task's `parent_id`. Returns the
  deduplicated refs in batch order; a parent-anchored add whose `parent_id`
  isn't in the map resolves to nothing and is dropped — the apply surfaces
  the real error.
  """
  @spec target_refs([map()], %{optional(term()) => target()}) :: [target()]
  def target_refs(operations, parent_targets \\ %{}) do
    operations |> count_by_target(parent_targets) |> Enum.map(&elem(&1, 0))
  end

  @doc """
  The unique existing-task `parent_id`s the batch's task-adds anchor on —
  the ids whose Initiative `count_by_target/2` can only learn from the
  `parent_targets` map. Mirrors `resolve_ref`'s priority order, so an add
  that already carries its own Initiative ref or an in-batch `parent_lid`
  never lists its `parent_id` here (a `parent_lid` CHAIN terminating at a
  `parent_id` is covered: the terminal op lists it itself). IO stays at
  the edge — the caller resolves each id (one task read apiece, deduped
  per batch) and hands back the map.
  """
  @spec existing_parent_ids([map()]) :: [term()]
  def existing_parent_ids(operations) do
    operations
    |> Enum.filter(&task_add?/1)
    |> Enum.flat_map(fn op ->
      data = Map.get(op, "data") || %{}

      if not is_binary(data["initiative_lid"]) and is_nil(data["initiative_id"]) and
           not is_binary(data["parent_lid"]) and not is_nil(data["parent_id"]),
         do: [data["parent_id"]],
         else: []
    end)
    |> Enum.uniq()
  end

  @doc "Whether a stored knobs value counts as unsettled (nil or blank)."
  @spec knobs_empty?(term()) :: boolean()
  def knobs_empty?(nil), do: true
  def knobs_empty?(knobs) when is_binary(knobs), do: String.trim(knobs) == ""
  def knobs_empty?(_), do: false

  defp task_add?(%{"op" => "add", "type" => "task"}), do: true
  defp task_add?(_), do: false

  # Targets whose session total (counter plus this batch) crosses the
  # threshold, as {ref, batch_adds, total} in batch order.
  @doc """
  Whether a batch delivers one reviewable list — the ramp's unit (m03.04 3.1
  iteration 2): every task-add's in-batch root hangs off the SAME single
  anchor (one existing task, one existing initiative, or one in-batch
  initiative), and the batch stays within `threshold/0` adds. Such a batch
  lands visibly as one checkable increment, so `evaluate/2` stretches its
  cumulative bound to `ramp_threshold/0`.
  """
  @spec coherent_unit?([map()]) :: boolean()
  def coherent_unit?(operations) do
    adds = Enum.filter(operations, &task_add?/1)

    task_lids = for %{"lid" => lid} <- adds, is_binary(lid), into: MapSet.new(), do: lid

    anchors =
      adds
      |> Enum.reject(fn op ->
        # In-batch children ride their root's anchor.
        parent_lid = (Map.get(op, "data") || %{})["parent_lid"]
        is_binary(parent_lid) and MapSet.member?(task_lids, parent_lid)
      end)
      |> Enum.map(&root_anchor/1)
      |> Enum.uniq()

    case anchors do
      [anchor] when not is_nil(anchor) -> length(adds) in 1..@task_add_threshold
      _ -> false
    end
  end

  # A root add's anchor. A parent_lid that survived the in-batch reject is
  # dangling — unknowable anchor, so nil (incoherent, the safe reading).
  defp root_anchor(op) do
    data = Map.get(op, "data") || %{}

    cond do
      is_binary(data["parent_lid"]) -> nil
      not is_nil(data["parent_id"]) -> {:parent_id, data["parent_id"]}
      is_binary(data["initiative_lid"]) -> {:initiative_lid, data["initiative_lid"]}
      not is_nil(data["initiative_id"]) -> {:initiative_id, data["initiative_id"]}
      true -> nil
    end
  end

  defp over_threshold(operations, cumulative, parent_targets) do
    # The ramp: one-list batches get the long leash; bulk, mixed-parent, or
    # oversized batches keep the tight bound and meet the readback confirm.
    bound = if coherent_unit?(operations), do: @ramp_threshold, else: @task_add_threshold

    operations
    |> count_by_target(parent_targets)
    |> Enum.map(fn {ref, n} -> {ref, n, n + cumulative.(ref)} end)
    |> Enum.filter(fn {_ref, _n, total} -> total > bound end)
  end

  defp resolve_ref(op, by_lid, parent_targets, seen) do
    data = Map.get(op, "data") || %{}

    cond do
      is_binary(data["initiative_lid"]) ->
        {:in_batch, data["initiative_lid"]}

      not is_nil(data["initiative_id"]) ->
        {:existing, data["initiative_id"]}

      is_binary(data["parent_lid"]) ->
        chase_parent(data["parent_lid"], by_lid, parent_targets, seen)

      # Anchored on an existing task: the caller-resolved map knows its
      # Initiative. A parent the map doesn't carry (unknown/foreign id, a
      # failed read) keeps the old dropped behavior — nil, uncounted — and
      # the apply surfaces the real error.
      not is_nil(data["parent_id"]) ->
        Map.get(parent_targets, data["parent_id"])

      true ->
        nil
    end
  end

  defp chase_parent(lid, by_lid, parent_targets, seen) do
    with false <- MapSet.member?(seen, lid),
         %{} = parent <- Map.get(by_lid, lid) do
      resolve_ref(parent, by_lid, parent_targets, MapSet.put(seen, lid))
    else
      _ -> nil
    end
  end

  # An in-batch Initiative is unsettled by definition; otherwise the first
  # existing candidate (batch order) whose fetched knobs are empty gates.
  # (Knobs are parked — m03.04 — so the fetched value is always empty and
  # every over-threshold existing target gates.)
  defp knobless_target(candidates, fetch) do
    case Enum.find(candidates, fn {ref, _n, _total} -> match?({:in_batch, _}, ref) end) do
      nil ->
        Enum.find_value(candidates, :pass, fn {{:existing, id}, _n, _total} = candidate ->
          case fetch.(id) do
            {:ok, initiative} ->
              if knobs_empty?(Map.get(initiative, "ai_knobs")), do: {:ok, candidate}

            {:error, _} ->
              nil
          end
        end)

      in_batch ->
        {:ok, in_batch}
    end
  end
end
