defmodule DoitMcp.ImportInterview do
  @moduledoc """
  The first-import interview (m03.04 2.8.10), pure like every guard: agents
  fail unprompted consideration but answer questions well, so an Initiative's
  FIRST import — import-scale task-adds (the floor, per batch or accumulated
  in the pressure window) into a live tree still under the floor with no
  recorded declaration — demands a structured declaration instead of prose:
  the source's item total, its completed count, exclusions (count + reason
  each), and its ordering scheme. The server validates the batch against the
  declared numbers, so a silent narrowing becomes an on-record false
  statement.

  The arithmetic is cumulative and refusal-precise: with the pressure
  window's counts folded in, a chunk that could still be consistent with the
  declaration NEVER refuses. It refuses only when the numbers cannot
  reconcile — cumulative adds past the declared importable total
  (total − exclusions), done-arriving adds past the declared completed count,
  or an import completing with fewer done arrivals than even the exclusions
  can absorb. One reconcilable-but-parked lane remains: an import completing
  with declared-complete work sitting in the declared exclusions — a scope
  narrowing only the operator adjudicates (the 2.8.8 park, reused).

  Decisions and messages only; IO (the snapshot read, the park consult, the
  declaration record) stays in `DoitMcp.Tools.ApplyOperations`.
  """

  alias DoitMcp.BatchShape

  @typedoc """
  A normalized declaration. `exclusions` carries the verbatim
  `%{count, reason}` entries when the agent just stated them (params), nil
  when read back from the server's record (the arithmetic only needs
  `excluded`).
  """
  @type declaration :: %{
          total: pos_integer(),
          completed: non_neg_integer(),
          excluded: non_neg_integer(),
          exclusions: [%{count: pos_integer(), reason: String.t()}] | nil,
          ordering: String.t() | nil
        }

  @doc """
  Whether a target is in first-import scope: its live tree (nil = unknowable,
  fail-open) still under the import floor while the import's cumulative adds
  (window plus batch) reach it.
  """
  @spec first_import?(non_neg_integer() | nil, non_neg_integer()) :: boolean()
  def first_import?(live, cumulative_adds) do
    is_integer(live) and live < BatchShape.import_floor() and
      cumulative_adds >= BatchShape.import_floor()
  end

  @doc """
  The declaration stated in the tool call's params — `:none` when no
  declaration field is present, `{:ok, declaration}`, or `{:invalid, message}`
  naming exactly what's wrong.
  """
  @spec from_params(map()) :: :none | {:ok, declaration()} | {:invalid, String.t()}
  def from_params(params) do
    total = Map.get(params, :declared_total)
    completed = Map.get(params, :declared_completed)
    exclusions = Map.get(params, :declared_exclusions)
    ordering = Map.get(params, :declared_ordering)

    if is_nil(total) and is_nil(completed) and is_nil(exclusions) and is_nil(ordering) do
      :none
    else
      validate(total, completed, exclusions || [], ordering)
    end
  end

  defp validate(total, completed, exclusions, ordering) do
    with :ok <- validate_total(total),
         :ok <- validate_completed(completed, total),
         {:ok, entries} <- validate_exclusions(exclusions, total),
         :ok <- validate_ordering(ordering) do
      {:ok,
       %{
         total: total,
         completed: completed,
         excluded: Enum.sum_by(entries, & &1.count),
         exclusions: entries,
         ordering: String.trim(ordering)
       }}
    else
      {:invalid, detail} ->
        {:invalid, "Import declaration invalid — nothing was applied. " <> detail}
    end
  end

  defp validate_total(total) when is_integer(total) and total > 0, do: :ok

  defp validate_total(_total),
    do: {:invalid, "`declared_total` must be the source's positive item count."}

  defp validate_completed(completed, total)
       when is_integer(completed) and completed >= 0 and completed <= total,
       do: :ok

  defp validate_completed(completed, total) do
    {:invalid,
     "`declared_completed` (#{inspect(completed)}) must sit between 0 and " <>
       "`declared_total` (#{total})."}
  end

  defp validate_exclusions(exclusions, total) when is_list(exclusions) do
    entries =
      Enum.map(exclusions, fn
        %{"count" => count, "reason" => reason}
        when is_integer(count) and count > 0 and is_binary(reason) ->
          if String.trim(reason) == "", do: :invalid, else: %{count: count, reason: reason}

        _entry ->
          :invalid
      end)

    excluded = entries |> Enum.reject(&(&1 == :invalid)) |> Enum.sum_by(& &1.count)

    cond do
      Enum.any?(entries, &(&1 == :invalid)) ->
        {:invalid,
         "each `declared_exclusions` entry needs a positive integer `count` " <>
           "and a non-empty `reason`."}

      excluded > total ->
        {:invalid, "declared exclusions (#{excluded}) cannot exceed `declared_total` (#{total})."}

      true ->
        {:ok, entries}
    end
  end

  defp validate_exclusions(_exclusions, _total) do
    {:invalid, "`declared_exclusions` must be a list of `{count, reason}` objects."}
  end

  defp validate_ordering(ordering) when is_binary(ordering) do
    if String.trim(ordering) == "" do
      {:invalid, ordering_detail()}
    else
      :ok
    end
  end

  defp validate_ordering(_ordering), do: {:invalid, ordering_detail()}

  defp ordering_detail do
    "`declared_ordering` must name the source's ordering scheme (`none` for an unordered list)."
  end

  @doc """
  The declaration the server's `task_count` consult carries for an already-
  declared Initiative, or nil.
  """
  @spec from_consult(map() | nil) :: declaration() | nil
  def from_consult(%{"source_total" => total, "source_completed" => completed} = map)
      when is_integer(total) and is_integer(completed) do
    excluded = map["excluded_count"]

    %{
      total: total,
      completed: completed,
      excluded: if(is_integer(excluded) and excluded >= 0, do: excluded, else: 0),
      exclusions: nil,
      ordering: if(is_binary(map["ordering"]), do: map["ordering"])
    }
  end

  def from_consult(_map), do: nil

  @doc """
  The cumulative arithmetic — `adds` and `done` fold the pressure window into
  this batch. `:ok` flows; `{:refuse, message}` when the numbers cannot
  reconcile; `:excluded_completed` when the import completes with declared-
  complete work absorbed by the declared exclusions — the caller parks that
  one for the operator (m03.04 2.8.8's machinery).
  """
  @spec check(declaration(), non_neg_integer(), non_neg_integer()) ::
          :ok | :excluded_completed | {:refuse, String.t()}
  def check(%{total: total, completed: completed, excluded: excluded}, adds, done) do
    importable = total - excluded

    cond do
      adds > importable ->
        {:refuse,
         mismatch(
           "cumulative adds reach #{adds} against an importable total of #{importable} " <>
             "(#{total} declared minus #{excluded} excluded)"
         )}

      done > completed ->
        {:refuse, mismatch("#{done} tasks arrive `done` against #{completed} declared complete")}

      adds == importable and done < completed and excluded < completed - done ->
        {:refuse,
         mismatch(
           "the import is complete at #{adds} adds with #{done} arrived `done`, and the " <>
             "#{excluded} declared exclusions cannot absorb the #{completed - done} " <>
             "missing completed items"
         )}

      adds == importable and done < completed ->
        :excluded_completed

      true ->
        :ok
    end
  end

  defp mismatch(detail) do
    "Import declaration mismatch — nothing was applied. This Initiative's declaration " <>
      "and the batch cannot reconcile: #{detail}. Completed source items import as " <>
      "`done: true` adds. Fix the batch — or, if the declaration mis-states the source, " <>
      "tell the operator."
  end

  @doc """
  The first-import demand — the readback-demand mechanics teaching the
  re-call with the declaration fields. `needs_readback?` folds the gate's own
  demand in, so one re-call satisfies both.
  """
  @spec demand_message(non_neg_integer(), boolean()) :: String.t()
  def demand_message(cumulative_adds, needs_readback?) do
    "First-import declaration required: this batch brings the Initiative's import to " <>
      "#{cumulative_adds} task-adds while its live tree is still under " <>
      "#{BatchShape.import_floor()} tasks and no declaration is on record. Nothing was " <>
      "applied; no operator step is needed. Re-call apply_operations with the SAME " <>
      "operations plus the declaration: `declared_total` (every item the source holds), " <>
      "`declared_completed` (how many it marks complete), `declared_exclusions` " <>
      "(what you are NOT importing — `{count, reason}` objects; omit for a whole " <>
      "import), `declared_ordering` (the source's ordering scheme). The server checks " <>
      "the arithmetic — completed items arrive as `done: true` adds — and every later " <>
      "chunk of this import is checked against the same declaration." <>
      if(needs_readback?,
        do: " This batch is also import-shaped: carry `readback` too.",
        else: ""
      )
  end

  @doc """
  The declared-exclusion refusal once the import is parked for the operator
  (2.8.8 reused): both recoveries, no attestation.
  """
  @spec parked_message(declaration(), non_neg_integer()) :: String.t()
  def parked_message(%{completed: completed}, done) do
    "Import parked — nothing was applied. The declaration leaves completed work out: " <>
      "#{completed} declared complete, #{done} arriving `done`, the rest sitting in " <>
      "your declared exclusions — narrowing an import's scope is the operator's call. " <>
      "Import the completed items as `done: true` adds instead, or once the operator " <>
      "approves this import in the app, re-send this SAME batch unchanged."
  end

  @doc "The refusal after the operator DISMISSED the parked import — latched per payload."
  @spec declined_message(String.t() | nil) :: String.t()
  def declined_message(reason \\ nil)

  def declined_message(reason) when is_binary(reason) do
    "Import refused — nothing was applied. The operator rejected this exact import " <>
      "in the app, saying: \"#{reason}\" Change the batch accordingly and re-send, " <>
      "or talk to them."
  end

  def declined_message(_reason) do
    "Import refused — nothing was applied. The operator rejected this exact import " <>
      "(its declaration excludes completed work) in the app without saying why. " <>
      "Change the batch — include the source's completed items as `done: true` " <>
      "adds — or talk to the operator."
  end

  @doc """
  The declaration rendered verbatim for the import's provenance record
  (m03.04 2.8.10.4) — the agent's stated numbers and reasons beside the
  server's shape facts.
  """
  @spec declaration_block(declaration()) :: String.t()
  def declaration_block(%{total: total, completed: completed, excluded: excluded} = decl) do
    exclusions =
      case exclusions_text(decl) do
        nil -> "- Exclusions: none declared."
        text -> "- Exclusions (#{excluded} items): #{text}."
      end

    Enum.join(
      [
        "Import declaration (agent-stated, server-checked):",
        "- Source: #{total} items, #{completed} complete.",
        exclusions,
        "- Ordering: #{decl.ordering || "(unstated)"}."
      ],
      "\n"
    )
  end

  @doc """
  The `POST /api/v1/import_declarations` body recording an accepted
  declaration Initiative-homed.
  """
  @spec record_attrs(declaration(), term()) :: map()
  def record_attrs(decl, initiative_id) do
    %{
      initiative_id: initiative_id,
      source_total: decl.total,
      source_completed: decl.completed,
      excluded_count: decl.excluded,
      exclusions: exclusions_text(decl),
      ordering: decl.ordering
    }
  end

  defp exclusions_text(%{exclusions: [_ | _] = entries}) do
    Enum.map_join(entries, "; ", fn %{count: count, reason: reason} ->
      "#{count} × #{reason}"
    end)
  end

  defp exclusions_text(_decl), do: nil
end
