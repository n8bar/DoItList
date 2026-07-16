defmodule DoitMcp.ImportGate do
  @moduledoc """
  Pure decision logic for `apply_operations`' import gate (m03.03 fix 10):
  a first big import into an Initiative whose `ai_knobs` is still unsettled
  gets held for the operator's readback confirmation instead of applying
  blind.

  The gate ships ARMED: `enabled?/0` — `DOITLIST_IMPORT_GATE=off` opts out;
  any other value, including unset, arms it — is `evaluate/2`'s very first,
  cheapest check, before anything is counted or fetched. (It shipped dark
  until the concurrent stdio transport landed, m03.03 item 5.11.1 — the old
  serial transport could never read the operator's answer.)

  The trigger is CUMULATIVE across the session (m03.03 item 5.11.2): sub-cap
  chunking is sanctioned, so no single batch tells the whole story. Each
  batch's task-adds are resolved per target Initiative and summed with the
  session counter (`DoitMcp.ImportGate.Counter`, recorded on successful
  applies); an armed gate holds the batch only when ALL of these hold:

    1. some Initiative's cumulative task-adds — session total plus this
       batch — cross `threshold/0`,
    2. the connected client advertised the `elicitation` capability in its
       initialize handshake (no capability → the gate silently steps aside;
       the skill's own gate rule is the only layer there), and
    3. that Initiative's import is still unsettled: the operator has not
       already confirmed one this session, and its `ai_knobs` is empty — an
       Initiative created in the same batch (via `lid`) is by definition
       knob-less; an existing target is fetched and checked.

  All effectful inputs (capability, session counter, confirm memory,
  Initiative fetch) are injected as funs, so the decision stays
  unit-testable; the elicitation wiring lives in `DoitMcp.Elicitation` and
  the flow in `DoitMcp.Tools.ApplyOperations`.
  """

  @task_add_threshold 30

  @typedoc "The Initiative a gated batch imports into."
  @type target :: {:in_batch, String.t()} | {:existing, term()}

  @doc "Cumulative task-add count above which a knob-less import is gated."
  @spec threshold() :: pos_integer()
  def threshold, do: @task_add_threshold

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
      reading an existing target Initiative (its `"ai_knobs"` is checked)
      (required)
    * `:cumulative` — 1-arity fun (`target -> non_neg_integer`); task-adds
      already applied to that Initiative this session (defaults to zero —
      single-batch semantics)
    * `:confirmed?` — 1-arity fun (`target -> boolean`); whether the operator
      already confirmed an import into that Initiative this session
      (defaults to false)

  Checks run cheapest-first (kill switch, counts, capability, knobs) and
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

    with true <- enabled?(),
         [_ | _] = candidates <- over_threshold(operations, cumulative),
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
  order, resolving in-batch `parent_lid` chains like `target_refs/1`. Adds
  with no resolvable Initiative are dropped. This is also the shape
  `DoitMcp.ImportGate.Counter.record/1` takes after a successful apply.
  """
  @spec count_by_target([map()]) :: [{target(), pos_integer()}]
  def count_by_target(operations) do
    task_adds = Enum.filter(operations, &task_add?/1)

    by_lid =
      for %{"lid" => lid} = op <- task_adds, is_binary(lid), into: %{}, do: {lid, op}

    refs =
      task_adds
      |> Enum.map(&resolve_ref(&1, by_lid, MapSet.new()))
      |> Enum.reject(&is_nil/1)

    counts = Enum.frequencies(refs)

    refs
    |> Enum.uniq()
    |> Enum.map(&{&1, Map.fetch!(counts, &1)})
  end

  @doc """
  Resolve each task-add op to the Initiative it targets, chasing in-batch
  `parent_lid` chains (an add without its own Initiative ref inherits its
  in-batch parent's). Returns the deduplicated refs in batch order; adds
  hanging off an existing task via `parent_id` resolve to nothing — their
  Initiative isn't knowable without a per-task read.
  """
  @spec target_refs([map()]) :: [target()]
  def target_refs(operations) do
    operations |> count_by_target() |> Enum.map(&elem(&1, 0))
  end

  @doc "Whether an `ai_knobs` value counts as unsettled (nil or blank)."
  @spec knobs_empty?(term()) :: boolean()
  def knobs_empty?(nil), do: true
  def knobs_empty?(knobs) when is_binary(knobs), do: String.trim(knobs) == ""
  def knobs_empty?(_), do: false

  defp task_add?(%{"op" => "add", "type" => "task"}), do: true
  defp task_add?(_), do: false

  # Targets whose session total (counter plus this batch) crosses the
  # threshold, as {ref, batch_adds, total} in batch order.
  defp over_threshold(operations, cumulative) do
    operations
    |> count_by_target()
    |> Enum.map(fn {ref, n} -> {ref, n, n + cumulative.(ref)} end)
    |> Enum.filter(fn {_ref, _n, total} -> total > @task_add_threshold end)
  end

  defp resolve_ref(op, by_lid, seen) do
    data = Map.get(op, "data") || %{}

    cond do
      is_binary(data["initiative_lid"]) -> {:in_batch, data["initiative_lid"]}
      not is_nil(data["initiative_id"]) -> {:existing, data["initiative_id"]}
      is_binary(data["parent_lid"]) -> chase_parent(data["parent_lid"], by_lid, seen)
      true -> nil
    end
  end

  defp chase_parent(lid, by_lid, seen) do
    with false <- MapSet.member?(seen, lid),
         %{} = parent <- Map.get(by_lid, lid) do
      resolve_ref(parent, by_lid, MapSet.put(seen, lid))
    else
      _ -> nil
    end
  end

  # An in-batch Initiative is knob-less by definition; otherwise the first
  # existing candidate (batch order) whose fetched ai_knobs is empty gates.
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
