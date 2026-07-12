defmodule DoitMcp.ImportGate do
  @moduledoc """
  Pure decision logic for `apply_operations`' import gate (m03.03 fix 10):
  a first big import into an Initiative whose `ai_knobs` is still unsettled
  gets held for the operator's readback confirmation instead of applying
  blind.

  The gate ships dark: `enabled?/0` — `DOITLIST_IMPORT_GATE=on`; any other
  value, including unset, passes — is `evaluate/2`'s very first, cheapest
  check, before anything is counted or fetched. The `apply_operations`
  moduledoc names why the default is off.

  An armed gate holds a batch only when ALL of these hold:

    1. it contains more than `threshold/0` task-add ops,
    2. the connected client advertised the `elicitation` capability in its
       initialize handshake (no capability → the gate silently steps aside;
       the skill's own gate rule is the only layer there), and
    3. the target Initiative's `ai_knobs` is empty — an Initiative created in
       the same batch (via `lid`) is by definition knob-less; an existing
       target is fetched and checked.

  Both effectful inputs (capability, Initiative fetch) are injected as funs,
  so the decision stays unit-testable; the elicitation wiring lives in
  `DoitMcp.Elicitation` and the flow in `DoitMcp.Tools.ApplyOperations`.
  """

  @task_add_threshold 30

  @typedoc "The Initiative a gated batch imports into."
  @type target :: {:in_batch, String.t()} | {:existing, term()}

  @doc "Task-add count above which a knob-less import is gated."
  @spec threshold() :: pos_integer()
  def threshold, do: @task_add_threshold

  @doc """
  Whether the gate is armed: `DOITLIST_IMPORT_GATE=on` in the adapter's
  environment (or the `:import_gate_enabled` app-env override in tests).
  Any other value, including unset, leaves it off.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(
      :doit_mcp,
      :import_gate_enabled,
      System.get_env("DOITLIST_IMPORT_GATE") == "on"
    )
  end

  @doc """
  Decide whether a batch must be held for operator confirmation.

  Options (both required):

    * `:elicitation?` — zero-arity fun; whether the client advertised the
      `elicitation` capability
    * `:fetch_initiative` — 1-arity fun (`id -> {:ok, map} | {:error, term}`)
      reading an existing target Initiative (its `"ai_knobs"` is checked)

  Checks run cheapest-first (kill switch, count, capability, knobs) and
  short-circuit, so nothing is counted while `enabled?/0` is false and the
  fetch only ever happens for an over-threshold batch from an
  elicitation-capable client. Returns `:pass` or
  `{:gate, %{task_adds: n, target: target}}`. A fetch error passes — the
  apply itself will surface the real error.
  """
  @spec evaluate([map()], keyword()) ::
          :pass | {:gate, %{task_adds: pos_integer(), target: target()}}
  def evaluate(operations, opts) when is_list(operations) do
    with true <- enabled?(),
         task_adds = count_task_adds(operations),
         true <- task_adds > @task_add_threshold,
         true <- Keyword.fetch!(opts, :elicitation?).(),
         {:ok, target} <- knobless_target(operations, Keyword.fetch!(opts, :fetch_initiative)) do
      {:gate, %{task_adds: task_adds, target: target}}
    else
      _ -> :pass
    end
  end

  @doc "Count of task-add ops in the batch."
  @spec count_task_adds([map()]) :: non_neg_integer()
  def count_task_adds(operations), do: Enum.count(operations, &task_add?/1)

  @doc """
  Resolve each task-add op to the Initiative it targets, chasing in-batch
  `parent_lid` chains (an add without its own Initiative ref inherits its
  in-batch parent's). Returns the deduplicated refs in batch order; adds
  hanging off an existing task via `parent_id` resolve to nothing — their
  Initiative isn't knowable without a per-task read.
  """
  @spec target_refs([map()]) :: [target()]
  def target_refs(operations) do
    task_adds = Enum.filter(operations, &task_add?/1)

    by_lid =
      for %{"lid" => lid} = op <- task_adds, is_binary(lid), into: %{}, do: {lid, op}

    task_adds
    |> Enum.map(&resolve_ref(&1, by_lid, MapSet.new()))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc "Whether an `ai_knobs` value counts as unsettled (nil or blank)."
  @spec knobs_empty?(term()) :: boolean()
  def knobs_empty?(nil), do: true
  def knobs_empty?(knobs) when is_binary(knobs), do: String.trim(knobs) == ""
  def knobs_empty?(_), do: false

  defp task_add?(%{"op" => "add", "type" => "task"}), do: true
  defp task_add?(_), do: false

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
  # existing target (batch order) whose fetched ai_knobs is empty gates.
  defp knobless_target(operations, fetch) do
    refs = target_refs(operations)

    case Enum.find(refs, &match?({:in_batch, _}, &1)) do
      nil ->
        Enum.find_value(refs, :pass, fn {:existing, id} = ref ->
          case fetch.(id) do
            {:ok, initiative} ->
              if knobs_empty?(Map.get(initiative, "ai_knobs")), do: {:ok, ref}

            {:error, _} ->
              nil
          end
        end)

      in_batch ->
        {:ok, in_batch}
    end
  end
end
