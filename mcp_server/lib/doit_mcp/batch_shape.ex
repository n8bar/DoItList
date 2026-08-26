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
      teaches at the moment of action and names the one override path
      (m03.04 2.8.5.3): a shape the operator actually asked for is approved
      by them in the app, and the same batch re-sent unchanged then flows —
      the agent never attests on their behalf.
    * `:pass` — nothing notable.

  The open-only bootstrap import (a new Initiative with import-scale
  task-adds, none arriving done) no longer refuses on shape (m03.04 2.8.7,
  demoted by 2.8.10): a first import demands a structured declaration and
  the ARITHMETIC decides — see `DoitMcp.ImportInterview`.

  `facts_block/1` renders the same counts for the import's provenance record
  (nil when nothing is notable), so a recorded readback shows the server's
  numbers under the agent's words — a rosy readback can't hide the shape. An
  initiative ADD is always notable: its `index_style` fact prints per add,
  so a recorded bootstrap always shows how the imported tree will render
  (numbered or not). An import-scale batch whose task-adds all arrive open
  is notable too (`open_only_adds/1`) — a stated fact on records, never a
  verdict.

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
  # A title short enough to appear inside unrelated prose by chance can't
  # signal a title-echo; only titles at least this long strip.
  @title_echo_min_chars 10

  @type verdict :: {:refuse, String.t()} | :pass

  @doc """
  Classify a batch's content shape. Scale-certain refusals compose every
  tripped reason into one teaching message; a sub-scale checklist refuses
  on its own message, whose recovery is subtasks or the operator's chat
  confirm (m03.04 2.8.4.2).
  """
  @spec classify([map()]) :: verdict()
  def classify(operations) do
    facts = analyze(operations)

    case refusal_reasons(facts) do
      [_ | _] = reasons ->
        {:refuse, refuse_message(reasons)}

      [] ->
        if facts.checklist_descriptions > 0 do
          {:refuse, checklist_message(facts)}
        else
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

  @doc """
  A task-add created complete: `"done" => true`, or the completed status set
  directly — the API's `add_done_to_status` vocabulary, exactly. Public so
  `ImportGate.done_by_target/2` counts done arrivals with the same words.
  """
  @spec done_add?(map()) :: boolean()
  def done_add?(op) do
    add_field(op, "done") == true or add_field(op, "status") == "done"
  end

  defp top_repeated_description(adds) do
    adds
    |> Enum.map(&boilerplate_key/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Map.values()
    |> Enum.max(fn -> 0 end)
  end

  # The repeat family a description belongs to. An exact repeat keys on
  # itself; a description that ECHOES its own title keys on what is left
  # once the title is stripped, so a per-task title can't disguise one
  # stamped template (m03.04 2.8.5 — a drive gave 324 tasks descriptions
  # reading "Imported checklist item from <file>. Full source item: <the
  # title again>", every string unique, the exact-repeat count zero).
  defp boilerplate_key(op) do
    desc = add_field(op, "description")

    if is_binary(desc) and String.length(String.trim(desc)) >= @boilerplate_min_chars do
      trimmed = String.trim(desc)

      case title_residual(trimmed, add_field(op, "title")) do
        nil -> trimmed
        residual -> {:title_echo, residual}
      end
    end
  end

  # What a description says BEYOND its own title — nil when the title isn't
  # echoed in it at all. Two tasks whose descriptions differ only by their
  # titles share a residual, so they land in one family.
  defp title_residual(desc, title) when is_binary(title) do
    trimmed = String.trim(title)

    if String.length(trimmed) >= @title_echo_min_chars and
         String.contains?(String.downcase(desc), String.downcase(trimmed)) do
      desc
      |> String.downcase()
      |> String.replace(String.downcase(trimmed), " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
    end
  end

  defp title_residual(_desc, _title), do: nil

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
    "Import content refused — nothing was applied. #{Enum.map_join(reasons, "; ", &String.capitalize/1)}. Always import the work inside each document as tasks, including completed items as `done: true` and preserving the source nesting; never create tasks for the documents themselves. Add a description only when it supplies detail absent from the title. Add one provenance comment per branch naming its source path; never repeat it on every task. If the operator explicitly requested the rejected content, wait for their approval in the app and then re-send the same batch unchanged."
  end

  # The snapshot the approval card shows (m03.04 3.1.9.2). Sampled from the
  # batch's DEEPEST branch on purpose: the failures that slip past the
  # arithmetic are structural — a flattened import has no depth to show, so
  # the card renders a flat list and the operator sees it at a glance.
  @sample_max_nodes 8
  @sample_max_siblings 2
  @sample_description_chars 100

  @doc """
  A depth-ordered snapshot of the batch's deepest branch — the ancestor
  chain down to the first deepest task-add, plus a couple of its siblings.
  `nil` when there are no task-adds. Shape: `%{"nodes" => [%{"title",
  "description", "depth"}]}`, ordered root-first, for the parked card.
  """
  @spec deep_sample([map()]) :: %{String.t() => list()} | nil
  def deep_sample(operations) do
    nodes = sample_nodes(operations)

    case nodes do
      [] -> nil
      nodes -> %{"nodes" => nodes}
    end
  end

  defp sample_nodes(operations) do
    adds = Enum.filter(operations, &task_add?/1)

    by_lid =
      for op <- adds, lid = Map.get(op, "lid"), is_binary(lid), into: %{}, do: {lid, op}

    depths = Enum.map(adds, &{&1, depth_of(&1, by_lid, 0)})

    case depths do
      [] ->
        []

      depths ->
        {deepest, max_depth} = Enum.max_by(depths, fn {_op, d} -> d end)

        chain = ancestors(deepest, by_lid, [])

        siblings =
          depths
          |> Enum.filter(fn {op, d} ->
            d == max_depth and op != deepest and parent_lid(op) == parent_lid(deepest)
          end)
          |> Enum.take(@sample_max_siblings)
          |> Enum.map(fn {op, d} -> {op, d} end)

        (chain ++ siblings)
        |> Enum.take(@sample_max_nodes)
        |> Enum.map(fn {op, d} -> render_node(op, d) end)
    end
  end

  # Depth by parent_lid chain — an add anchored on a real `parent_id` or on
  # an Initiative is depth 1 here; the batch can't see above itself.
  defp depth_of(op, by_lid, seen) when seen < @sample_max_nodes do
    case parent_lid(op) do
      nil ->
        1

      lid ->
        case Map.get(by_lid, lid) do
          nil -> 1
          parent -> 1 + depth_of(parent, by_lid, seen + 1)
        end
    end
  end

  defp depth_of(_op, _by_lid, _seen), do: 1

  defp ancestors(op, by_lid, acc) do
    acc = [{op, depth_of(op, by_lid, 0)} | acc]

    case parent_lid(op) do
      nil ->
        acc

      lid ->
        case Map.get(by_lid, lid) do
          nil -> acc
          parent -> ancestors(parent, by_lid, acc)
        end
    end
  end

  defp parent_lid(op) do
    case add_field(op, "parent_lid") do
      lid when is_binary(lid) -> lid
      _ -> nil
    end
  end

  defp render_node(op, depth) do
    %{
      "title" => to_string(add_field(op, "title") || "(untitled)"),
      "description" => truncated_description(add_field(op, "description")),
      "depth" => depth
    }
  end

  defp truncated_description(desc) when is_binary(desc) do
    trimmed = String.trim(desc)

    cond do
      trimmed == "" -> nil
      String.length(trimmed) <= @sample_description_chars -> trimmed
      true -> String.slice(trimmed, 0, @sample_description_chars) <> "…"
    end
  end

  defp truncated_description(_), do: nil

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
    "Import content refused — nothing was applied. #{facts.checkbox_lines} markdown-checkbox lines appear inside #{facts.checklist_descriptions} new task descriptions. Always import each checkbox as a subtask, preserving checked items as `done: true`. If the operator explicitly wants the checklists kept as description prose, wait for their approval in the app and then re-send the same batch unchanged."
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
