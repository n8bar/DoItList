defmodule DoitMcp.BatchShape do
  @moduledoc """
  One validation pass over a batch's content shape, run by `apply_operations`
  before anything posts (m03.04 3.1 iteration 1; refusal-only since item 36
  — no verdict stops for a human). Two buckets:

    * `{:refuse, message}` — content shape the import should not land as:
      a file-mirror import (path-like titles + whole-file descriptions),
      embedded checklists at scale (the dropped task layer as description
      markup), boilerplate (one description stamped across dozens of tasks),
      and sub-scale checklist descriptions (checkboxable lines are what this
      product turns into tasks — import them as subtasks). Every message
      teaches at the moment of action and names the override path: a shape
      the operator explicitly asked for re-calls with
      `operator_confirmed: true` plus `readback` after the agent confirms
      with them in chat; the attestation is stamped into the import's
      provenance record.
    * `{:refuse_open_only, info}` — the open-only bootstrap import (m03.04
      2.8.7: a new Initiative with import-scale task-adds, none arriving
      done — the dropped completed layer). Its override is NOT attestation:
      the adapter parks the refused import for the operator's one-click
      in-app approval (m03.04 2.8.8) and picks the message —
      `open_only_message/1` (parked, both recoveries) or
      `open_only_declined_message/1` (the operator dismissed the park).
      `info` carries `adds` and `initiative_name` for the park.
    * `:pass` — nothing notable.

  `facts_block/1` renders the same counts for the import's provenance record
  (nil when nothing is notable), so a recorded readback shows the server's
  numbers under the agent's words — a rosy readback can't hide the shape. An
  initiative ADD is always notable: its `index_style` fact prints per add,
  so a recorded bootstrap always shows how the imported tree will render
  (numbered or not). An import-scale batch whose task-adds all arrive open
  is notable too (`open_only_adds/1`) — a stated fact on records; only the
  BOOTSTRAP form of that signature refuses (mid-work bulk adds to an
  existing initiative never carry an initiative add, so they can't
  false-positive).

  Pure; adapter-side judgment like every guard (the API stays dumb — thin-layer
  guardrail). Thresholds are retunable module attributes. Checkbox detection
  shares `DoitMcp.IngestReport.checkbox_line_pattern/0` so the audit tool and
  this pass can never disagree on what a checklist is.
  """

  alias DoitMcp.IngestReport

  # --- Thresholds (retunable) ------------------------------------------------

  # Below this many task-adds a batch never refuses as a mirror — small
  # batches are cheap to fix by hand and path-y titles happen.
  @mirror_min_adds 10
  # A mirror import: at least half the titles name files AND at least a
  # quarter of the adds carry whole-file-sized descriptions.
  @mirror_pathlike_ratio 0.5
  @mirror_long_desc_ratio 0.25
  # A description this long inside a task-add reads as pasted source prose.
  @long_description_chars 2_000
  # A description "carries a checklist" at this many checkbox lines; this
  # many checklist-bearing descriptions (or total lines) is import-scale.
  @checklist_min_lines 2
  @checklist_refuse_descriptions 10
  @checklist_refuse_lines 50
  # Boilerplate: one description string (of at least this length) stamped on
  # this many tasks.
  @boilerplate_repeats 10
  @boilerplate_min_chars 20

  @type open_only_info :: %{adds: pos_integer(), initiative_name: String.t()}
  @type verdict :: {:refuse, String.t()} | {:refuse_open_only, open_only_info()} | :pass

  @doc """
  Classify a batch's content shape. Scale-certain refusals compose every
  tripped reason into one teaching message; a sub-scale checklist refuses
  on its own message, whose recovery is subtasks or the operator's chat
  confirm (m03.04 2.8.4.2); an open-only bootstrap returns its park info —
  the caller parks and picks the message (m03.04 2.8.8).
  """
  @spec classify([map()]) :: verdict()
  def classify(operations) do
    facts = analyze(operations)

    case refusal_reasons(facts) do
      [_ | _] = reasons ->
        {:refuse, refuse_message(reasons)}

      [] ->
        cond do
          open_only_bootstrap?(facts) ->
            {:refuse_open_only,
             %{adds: facts.adds, initiative_name: first_initiative_name(operations)}}

          facts.checklist_descriptions > 0 ->
            {:refuse, checklist_message(facts)}

          true ->
            :pass
        end
    end
  end

  @doc """
  The task-add count at which a batch reads import-scale — the mirror and
  open-only floors here, and `apply_operations`' import-flavor floor for its
  success riders (one constant, never duplicated).
  """
  @spec import_floor() :: pos_integer()
  def import_floor, do: @mirror_min_adds

  @doc """
  The server-computed counts for an import's provenance record — nil when
  nothing is notable (the record then carries no facts section). An
  initiative add is always notable: each one contributes an `index_style`
  line, read purely from the op's data. Facts only — `classify/1` verdicts
  don't move.
  """
  @spec facts_block([map()]) :: String.t() | nil
  def facts_block(operations) do
    facts = analyze(operations)

    task_lines =
      Enum.filter(
        [
          facts.pathlike_titles > 0 &&
            "- #{facts.pathlike_titles} of #{facts.adds} new task titles look like file paths/names.",
          facts.long_descriptions > 0 &&
            "- #{facts.long_descriptions} new descriptions run #{@long_description_chars}+ characters (whole-file sized).",
          facts.checkbox_lines > 0 &&
            "- #{facts.checkbox_lines} markdown-checkbox lines sit inside #{facts.checklist_descriptions} new descriptions.",
          facts.top_repeated_description >= 2 &&
            "- One description string repeats on #{facts.top_repeated_description} tasks.",
          facts.adds >= @mirror_min_adds && facts.done_adds == 0 &&
            "- All #{facts.adds} new tasks arrive open — none marked done."
        ],
        &is_binary/1
      )

    # The container's rendering fact leads the task-shape counts.
    lines = initiative_style_lines(operations) ++ task_lines

    case lines do
      [] -> nil
      lines -> Enum.join(["Server-computed shape facts:" | lines], "\n")
    end
  end

  @doc """
  The batch's task-add count when an import-scale batch (the mirror floor)
  creates every task open — nil otherwise (any done add, or sub-scale). A
  done add carries `"done" => true` or `"status" => "done"`, the API's
  completion vocabulary (`add_done_to_status`). A stated fact for records;
  only the BOOTSTRAP form of the signature refuses in `classify/1`
  (m03.04 2.8.7).
  """
  @spec open_only_adds([map()]) :: pos_integer() | nil
  def open_only_adds(operations) do
    facts = analyze(operations)
    if facts.adds >= @mirror_min_adds and facts.done_adds == 0, do: facts.adds
  end

  # --- Facts -----------------------------------------------------------------

  # One line per initiative ADD, read purely from the op's data: unset (no
  # key, nil, or blank) is itself the fact — the tasks render unnumbered.
  defp initiative_style_lines(operations) do
    for op <- operations, initiative_add?(op) do
      name = initiative_display_name(op)
      style = add_field(op, "index_style")

      if is_binary(style) and String.trim(style) != "" do
        ~s(- New Initiative "#{name}" sets index_style: #{style}.)
      else
        ~s(- New Initiative "#{name}" leaves index_style unset — tasks render unnumbered.)
      end
    end
  end

  defp analyze(operations) do
    adds = Enum.filter(operations, &task_add?/1)

    checklist_counts =
      for op <- adds,
          desc = add_field(op, "description"),
          is_binary(desc),
          count = length(Regex.scan(IngestReport.checkbox_line_pattern(), desc)),
          count >= @checklist_min_lines,
          do: count

    %{
      adds: length(adds),
      initiative_adds: Enum.count(operations, &initiative_add?/1),
      done_adds: Enum.count(adds, &done_add?/1),
      pathlike_titles: Enum.count(adds, &pathlike_title?(add_field(&1, "title"))),
      long_descriptions:
        Enum.count(adds, fn op ->
          desc = add_field(op, "description")
          is_binary(desc) and String.length(desc) >= @long_description_chars
        end),
      checklist_descriptions: length(checklist_counts),
      checkbox_lines: Enum.sum(checklist_counts),
      top_repeated_description: top_repeated_description(adds)
    }
  end

  # A task-add created complete: `"done" => true`, or the completed status
  # set directly — the API's `add_done_to_status` vocabulary, exactly.
  defp done_add?(op) do
    add_field(op, "done") == true or add_field(op, "status") == "done"
  end

  defp top_repeated_description(adds) do
    adds
    |> Enum.map(&add_field(&1, "description"))
    |> Enum.filter(fn desc ->
      is_binary(desc) and String.length(String.trim(desc)) >= @boilerplate_min_chars
    end)
    |> Enum.frequencies()
    |> Map.values()
    |> Enum.max(fn -> 0 end)
  end

  # --- Refusals --------------------------------------------------------------

  defp refusal_reasons(facts) do
    Enum.filter(
      [mirror_reason(facts), checklist_scale_reason(facts), boilerplate_reason(facts)],
      &is_binary/1
    )
  end

  defp mirror_reason(%{adds: adds} = facts) when adds >= @mirror_min_adds do
    if facts.pathlike_titles >= adds * @mirror_pathlike_ratio and
         facts.long_descriptions >= adds * @mirror_long_desc_ratio do
      "#{facts.pathlike_titles} of #{adds} new task titles look like file paths/names and " <>
        "#{facts.long_descriptions} descriptions run #{@long_description_chars}+ characters " <>
        "(whole-file sized) — a file-mirror import"
    end
  end

  defp mirror_reason(_facts), do: nil

  defp checklist_scale_reason(facts) do
    if facts.checklist_descriptions >= @checklist_refuse_descriptions or
         facts.checkbox_lines >= @checklist_refuse_lines do
      "#{facts.checkbox_lines} markdown-checkbox lines sit inside " <>
        "#{facts.checklist_descriptions} new descriptions — those checklists are the " <>
        "task layer this import dropped"
    end
  end

  defp boilerplate_reason(facts) do
    if facts.top_repeated_description >= @boilerplate_repeats do
      "one description string is stamped on #{facts.top_repeated_description} tasks — " <>
        "boilerplate padding"
    end
  end

  defp refuse_message(reasons) do
    "Batch shape refused — nothing was applied. " <>
      Enum.map_join(reasons, "; ", &String.capitalize/1) <>
      ". Import the work inside the documents — completable items become tasks, nested " <>
      "as the source nests them — not the documents themselves; cite a source file by " <>
      "path in a provenance comment instead of pasting its contents. If the operator " <>
      "explicitly asked for this exact shape, confirm it with them in chat, then " <>
      "re-call with `operator_confirmed: true` plus `readback` — the attestation is " <>
      "stamped into the import's provenance record."
  end

  # The open-only bootstrap refusal (m03.04 2.8.7): an initiative add plus
  # import-scale task-adds none arriving done is the unambiguous open-only
  # import signature — mid-work bulk adds to an existing initiative never
  # carry an initiative add, so they can't false-positive.
  defp open_only_bootstrap?(facts) do
    facts.initiative_adds > 0 and facts.adds >= @mirror_min_adds and facts.done_adds == 0
  end

  @doc """
  The open-only bootstrap refusal once the import is PARKED for the
  operator (m03.04 2.8.8) — both recoveries, no attestation: this refusal's
  only override is the operator's in-app click.
  """
  @spec open_only_message(open_only_info()) :: String.t()
  def open_only_message(%{adds: adds}) do
    "Batch shape refused — nothing was applied. All #{adds} tasks bootstrapping the " <>
      "new Initiative arrive open — the open-only import signature. The source " <>
      "imports WHOLE: include the items it marks complete as adds with `done: true` " <>
      "and re-send, or roll-up progress lies. If the plan is genuinely all-open, or " <>
      "the operator chose open-only, this import now awaits their one-click approval " <>
      "in the app — once they approve it there, re-send this SAME batch unchanged."
  end

  @doc """
  The open-only refusal after the operator DISMISSED the parked import
  (m03.04 2.8.8) — the decline latches for this exact payload.
  """
  @spec open_only_declined_message(open_only_info()) :: String.t()
  def open_only_declined_message(%{adds: adds}) do
    "Batch shape refused — nothing was applied. The operator declined this exact " <>
      "open-only import (all #{adds} tasks arriving open) in the app. Change the " <>
      "batch — include the source's completed items as adds with `done: true` — or " <>
      "talk to the operator."
  end

  @doc "The batch's first initiative-add name, for the park — `(unnamed)` when blank."
  @spec first_initiative_name([map()]) :: String.t()
  def first_initiative_name(operations) do
    case Enum.find(operations, &initiative_add?/1) do
      nil -> "(unnamed)"
      op -> initiative_display_name(op)
    end
  end

  defp initiative_display_name(op) do
    case add_field(op, "name") do
      name when is_binary(name) ->
        if String.trim(name) == "", do: "(unnamed)", else: name

      _ ->
        "(unnamed)"
    end
  end

  # The sub-scale checklist refusal (m03.04 2.8.4.2) — the recovery words:
  # subtasks, or the operator's chat confirm.
  defp checklist_message(facts) do
    "Batch shape refused — nothing was applied. #{facts.checkbox_lines} " <>
      "markdown-checkbox lines sit inside #{facts.checklist_descriptions} new task " <>
      "descriptions, and checklists are what DoItList turns into tasks. Import them " <>
      "as subtasks instead — or ask the operator in chat; if they want the checklists " <>
      "kept as description prose, re-call with `operator_confirmed: true` plus " <>
      "`readback`."
  end

  # --- Op access -------------------------------------------------------------

  defp task_add?(%{"op" => "add", "type" => "task"}), do: true
  defp task_add?(_), do: false

  defp initiative_add?(%{"op" => "add", "type" => "initiative"}), do: true
  defp initiative_add?(_), do: false

  defp add_field(op, key) do
    case Map.get(op, "data") do
      data when is_map(data) -> Map.get(data, key)
      _ -> nil
    end
  end

  # A title that names a file: carries a path separator, or ends in a
  # letter-led dot-extension (so "Ship v1.2" doesn't count).
  defp pathlike_title?(title) when is_binary(title) do
    String.contains?(title, "/") or String.contains?(title, "\\") or
      Regex.match?(~r/\.[a-z][a-z0-9]{0,4}\z/i, String.trim(title))
  end

  defp pathlike_title?(_), do: false
end
