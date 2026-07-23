defmodule DoitMcp.BatchShape do
  @moduledoc """
  One validation pass over a batch's content shape, run by `apply_operations`
  before anything posts (m03.04 3.1 iteration 1). One pass, three buckets —
  not a mechanism per failure:

    * `{:refuse, message}` — mechanically certain garbage at batch scale:
      a file-mirror import (path-like titles + whole-file descriptions),
      embedded checklists at scale (the dropped task layer as description
      markup), boilerplate (one description stamped across dozens of tasks).
      The message teaches at the moment of action and names the override
      path: an operator-instructed shape re-calls with `readback` plus a
      `settled` entry quoting the instruction, and the operator vets it on
      the confirm form.
    * `{:hold, question}` — sub-scale checklist content: checkboxable lines
      are what this product turns into tasks, so the operator decides
      subtasks-vs-prose; too ambiguous to refuse, too on-the-nose to ignore.
    * `:pass` — nothing notable.

  `facts_block/1` renders the same counts for the gate's confirm form (nil
  when nothing is notable), so any held batch shows the server's numbers
  under the agent's readback — a rosy readback can't hide the shape.

  Pure; adapter-side judgment like every gate (the API stays dumb — thin-layer
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

  @type verdict :: {:refuse, String.t()} | {:hold, String.t()} | :pass

  @doc """
  Classify a batch's content shape. Refusals compose every tripped reason
  into one teaching message; the hold question is the checklist ask.
  """
  @spec classify([map()]) :: verdict()
  def classify(operations) do
    facts = analyze(operations)

    case refusal_reasons(facts) do
      [_ | _] = reasons ->
        {:refuse, refuse_message(reasons)}

      [] ->
        if facts.checklist_descriptions > 0,
          do: {:hold, checklist_question(facts)},
          else: :pass
    end
  end

  @doc """
  The server-computed counts for a held batch's confirm form — nil when
  nothing is notable (the form then carries no facts section).
  """
  @spec facts_block([map()]) :: String.t() | nil
  def facts_block(operations) do
    facts = analyze(operations)

    lines =
      Enum.filter(
        [
          facts.pathlike_titles > 0 &&
            "- #{facts.pathlike_titles} of #{facts.adds} new task titles look like file paths/names.",
          facts.long_descriptions > 0 &&
            "- #{facts.long_descriptions} new descriptions run #{@long_description_chars}+ characters (whole-file sized).",
          facts.checkbox_lines > 0 &&
            "- #{facts.checkbox_lines} markdown-checkbox lines sit inside #{facts.checklist_descriptions} new descriptions.",
          facts.top_repeated_description >= 2 &&
            "- One description string repeats on #{facts.top_repeated_description} tasks."
        ],
        &is_binary/1
      )

    case lines do
      [] ->
        nil

      lines ->
        block = Enum.join(["Server-computed shape facts:" | lines], "\n")

        if facts.checklist_descriptions > 0,
          do: block <> "\n" <> checklist_question(facts),
          else: block
    end
  end

  # --- Facts -----------------------------------------------------------------

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
      "explicitly asked for this exact shape, re-call with `readback` plus a `settled` " <>
      "entry quoting their instruction — they will be asked to confirm it."
  end

  defp checklist_question(facts) do
    "#{facts.checkbox_lines} markdown-checkbox lines sit inside " <>
      "#{facts.checklist_descriptions} new task descriptions. Checklists are what " <>
      "DoItList turns into tasks — should these import as subtasks instead? apply keeps " <>
      "them as description prose; correct with instructions to convert them."
  end

  # --- Op access -------------------------------------------------------------

  defp task_add?(%{"op" => "add", "type" => "task"}), do: true
  defp task_add?(_), do: false

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
