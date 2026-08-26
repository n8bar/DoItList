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
          ordering: String.t() | nil,
          sources: [%{path: String.t(), checkbox_lines: non_neg_integer()}] | nil
        }

  # The declared item total may fall below the sources' mechanical checkbox
  # count — headings, prose bullets, and nested restatements are real — but
  # not by an order of magnitude. Below this fraction the two statements
  # describe different documents (m03.04 2.8.11).
  @coverage_floor 0.5

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
    sources = Map.get(params, :declared_sources)

    if is_nil(total) and is_nil(completed) and is_nil(exclusions) and is_nil(ordering) and
         is_nil(sources) do
      :none
    else
      validate(total, completed, exclusions || [], ordering, sources)
    end
  end

  defp validate(total, completed, exclusions, ordering, sources) do
    with :ok <- validate_total(total),
         :ok <- validate_completed(completed, total),
         {:ok, entries} <- validate_exclusions(exclusions, total),
         :ok <- validate_ordering(ordering),
         {:ok, source_entries} <- validate_sources(sources),
         :ok <- validate_coverage(total, source_entries) do
      {:ok,
       %{
         total: total,
         completed: completed,
         excluded: Enum.sum_by(entries, & &1.count),
         exclusions: entries,
         ordering: String.trim(ordering),
         sources: source_entries
       }}
    else
      {:invalid, detail} ->
        {:invalid, "Import declaration invalid — nothing was applied. " <> detail}
    end
  end

  # The evidence half of the declaration (m03.04 2.8.11). Every other field
  # restates the agent's PLAN, so a misread source produces numbers that
  # agree with the batch it was always going to send. This one is about the
  # FILE: how many lines match a markdown checkbox. An agent that decided a
  # milestone is one task still counted the same lines underneath it.
  defp validate_sources(sources) when is_list(sources) and sources != [] do
    entries =
      Enum.map(sources, fn
        %{"path" => path, "checkbox_lines" => lines}
        when is_binary(path) and is_integer(lines) and lines >= 0 ->
          if String.trim(path) == "",
            do: :invalid,
            else: %{path: String.trim(path), checkbox_lines: lines}

        _entry ->
          :invalid
      end)

    if Enum.any?(entries, &(&1 == :invalid)) do
      {:invalid,
       "Each `declared_sources` entry must contain a non-empty string `path` and a non-negative integer `checkbox_lines`. Always count markdown-checkbox lines from that file; never infer the count from the batch you constructed."}
    else
      {:ok, entries}
    end
  end

  defp validate_sources(_sources) do
    {:invalid,
     "`declared_sources` must be a non-empty list containing every source document read as a `{path, checkbox_lines}` object."}
  end

  # The one check the plan can't satisfy by agreeing with itself.
  defp validate_coverage(total, sources) do
    lines = Enum.sum_by(sources, & &1.checkbox_lines)

    if lines > 0 and total < lines * @coverage_floor do
      {:invalid,
       "`declared_sources` counts #{lines} markdown-checkbox lines across #{length(sources)} file(s), but `declared_total` contains only #{total} items. Always count each checkbox line as a source item and import it as a task with the source nesting. If a line is genuinely not work, still include it in `declared_total` and add a reasoned `declared_exclusions` entry."}
    else
      :ok
    end
  end

  defp validate_total(total) when is_integer(total) and total > 0, do: :ok

  defp validate_total(_total),
    do: {:invalid, "`declared_total` must be a positive integer counting every source item."}

  defp validate_completed(completed, total)
       when is_integer(completed) and completed >= 0 and completed <= total,
       do: :ok

  defp validate_completed(completed, total) do
    {:invalid,
     "`declared_completed` (#{inspect(completed)}) must be an integer from 0 through `declared_total` (#{total})."}
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
         "Each `declared_exclusions` entry must contain a positive integer `count` and a non-empty string `reason`."}

      excluded > total ->
        {:invalid,
         "The total `declared_exclusions` count (#{excluded}) must not exceed `declared_total` (#{total})."}

      true ->
        {:ok, entries}
    end
  end

  defp validate_exclusions(_exclusions, _total) do
    {:invalid,
     "`declared_exclusions` must be a list of `{count, reason}` objects; omit the field when nothing is excluded."}
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
    "`declared_ordering` must name the source's ordering scheme; use `none` only when the source is unordered."
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
      ordering: if(is_binary(map["ordering"]), do: map["ordering"]),
      sources: nil
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
    "Import declaration mismatch — nothing was applied: #{detail}. Reconcile the batch with the declaration, always importing completed source items as `done: true`. If the declaration misstates the source, tell the operator instead of altering the batch to fit it."
  end

  @doc """
  The first-import demand — the readback-demand mechanics teaching the
  re-call with the declaration fields. `needs_readback?` folds the gate's own
  demand in, so one re-call satisfies both.
  """
  @spec demand_message(non_neg_integer(), boolean()) :: String.t()
  def demand_message(cumulative_adds, needs_readback?) do
    "First-import declaration required — nothing was applied; no operator step is needed. This batch raises the Initiative's import to #{cumulative_adds} task adds while its live tree has fewer than #{BatchShape.import_floor()} tasks and no declaration is recorded. Re-call `apply_operations` with the same operations plus a declaration derived from the source, never from the batch you constructed: `declared_sources` for every document read as `{path, checkbox_lines}` counted from that file, `declared_total` for every source item, `declared_completed` for every completed source item, `declared_exclusions` as `{count, reason}` objects or omitted for a whole import, and `declared_ordering` for the source scheme. Completed items must arrive as `done: true`; every later chunk is checked against this declaration." <>
      if(needs_readback?,
        do: " This batch also requires `readback`; include it in the same call.",
        else: ""
      )
  end

  @doc """
  The declared-exclusion refusal once the import is parked for the operator
  (2.8.8 reused): both recoveries, no attestation.
  """
  @spec parked_message(declaration(), non_neg_integer()) :: String.t()
  def parked_message(%{completed: completed}, done) do
    "Import parked — nothing was applied. The declaration contains #{completed} completed items, but only #{done} arrive as `done: true`; the rest are in the exclusions. Always add the omitted completed items as `done: true`, or wait for the operator to approve the narrower scope in the app and then re-send the same batch unchanged."
  end

  @doc "The refusal after the operator DISMISSED the parked import — latched per payload."
  @spec declined_message(String.t() | nil) :: String.t()
  def declined_message(reason \\ nil)

  def declined_message(reason) when is_binary(reason) do
    "Import refused — nothing was applied. The operator rejected this exact import in the app: \"#{reason}\" Never re-send it unchanged. Revise the batch to follow their reason, or ask them to resolve any ambiguity."
  end

  def declined_message(_reason) do
    "Import refused — nothing was applied. The operator rejected this exact import, which excludes completed work, without giving a reason. Never re-send it unchanged. Include every completed source item as `done: true`, or ask the operator how to proceed."
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
        sources_line(decl),
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

  defp sources_line(%{sources: [_ | _] = sources}) do
    "- Documents read: " <>
      Enum.map_join(sources, "; ", fn %{path: path, checkbox_lines: lines} ->
        "#{path} (#{lines} checkbox lines)"
      end) <> "."
  end

  defp sources_line(_decl), do: "- Documents read: (not recorded)."

  defp exclusions_text(%{exclusions: [_ | _] = entries}) do
    Enum.map_join(entries, "; ", fn %{count: count, reason: reason} ->
      "#{count} × #{reason}"
    end)
  end

  defp exclusions_text(_decl), do: nil
end
