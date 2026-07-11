defmodule DoitMcp.IngestReport do
  @moduledoc """
  The `ingest_report` lint facts (m03.03 item 5.5), computed as a pure function
  over one decoded Initiative tree read (`GET /api/v1/initiatives/:id`) plus
  the flat list of decoded comments the tool composes from the per-task
  comment reads (`comment_thread_ids/1` names the threads to fetch) — no
  HTTP in here, so the whole report is unit-testable off fixture maps.

  Facts only: counts, ids, and matched substrings. No verdicts, no thresholds —
  the tool measures, the companion skill judges, the product never interprets.

  Fact classes (`build/2` output, flat):

    * shape — `task_count`, `depth_histogram` (`%{"depth" => count}`),
      `leaf_count` / `branch_count`, `top_level_index_range` (`"first..last"`,
      `nil` for an empty tree).
    * description coverage — `with_description` / `without_description` counts
      (blank counts as without) + `no_description_task_ids`.
    * provenance coverage — `top_rank_no_comment_task_ids`: top-rank (depth 0)
      tasks whose `comment_count` is zero.
    * un-anchored reference candidates — `unanchored_reference_candidates`:
      substrings in titles/descriptions shaped like `M<n>`, a dotted index path
      (2+ segments), or `task <n>`, outside `%<id>` tokens, as
      `%{task_id, field, matched_text}`. Heuristic; false positives expected.
    * path-like strings — `path_like_strings`: slash-separated path shapes in
      descriptions, as `%{task_id, matched_text}`.
    * journal markers in descriptions — `journal_markers_in_descriptions`:
      descriptions carrying a journal marker (`Decision:`, `Verified:`,
      `Locked decisions:`, `Verification:` — case-sensitive, at line start or
      after whitespace), as `%{task_id, matched_text}`. Journaling belongs in
      comments; the marker list is a heuristic floor, not a grammar.
    * long comments — `long_comments`: comments whose body exceeds
      #{300} characters, as `%{comment_id, task_id}`. Nothing is excluded —
      the audit explains sanctioned long ones (like itself).
    * context — `ai_knobs_set` (boolean, never the content), `initiative_id`.

  Every id/entry list is capped: the first #{20} items plus an `"and N more"`
  string tail when longer. List order is tree order (depth-first, pre-order).
  """

  @cap 20
  @long_comment_chars 300

  # Compiled regexes hold a runtime reference (OTP 28+), so they can't live in
  # module attributes — plain functions instead.

  # A resolved cross-reference token as the %-notation editor persists it:
  # `%<id>` with ASCII angle brackets (see assets/js/refs.js in the main
  # app). Replaced with a single space before the reference scan, so token
  # content is never a candidate and the removal can't merge adjacent digits
  # into a fabricated match.
  defp ref_token, do: ~r/%<\d+>/

  # Reference-shaped strings that are NOT id-anchored: a milestone tag `M<n>`,
  # a dotted index path with 2+ segments, or a literal "task <n>".
  defp candidate_patterns do
    [
      ~r/\bM\d+\b/,
      ~r/\b\d+(?:\.\d+)+\b/,
      ~r/\btask\s+\d+\b/i
    ]
  end

  # A slash-separated path shape.
  defp path_pattern, do: ~r|[\w.\-]+\/[\w.\/\-]+|

  # Journal markers that belong in comments, not descriptions (drive-4 fix 4).
  # Case-sensitive, at line start or after whitespace; a heuristic floor, not
  # a grammar — mid-word or lowercase forms deliberately don't match.
  defp journal_marker_pattern do
    ~r/(?:^|\s)(Decision:|Verified:|Locked decisions:|Verification:)/m
  end

  @doc """
  Compute the full fact report over a decoded tree-read body (string keys)
  and the flat list of decoded comments fetched for `comment_thread_ids/1`
  (string keys; tombstones carry a `nil` body and never measure as long).
  """
  def build(tree, comments \\ []) when is_map(tree) and is_list(comments) do
    top = Map.get(tree, "tasks") || []
    # [{task, depth}] in tree order (depth-first, pre-order).
    flat = flatten(top, 0)

    {with_desc, without_desc} =
      Enum.split_with(flat, fn {task, _} -> present?(task["description"]) end)

    %{
      initiative_id: tree["id"],
      task_count: length(flat),
      leaf_count: Enum.count(flat, fn {task, _} -> children(task) == [] end),
      branch_count: Enum.count(flat, fn {task, _} -> children(task) != [] end),
      depth_histogram: Enum.frequencies_by(flat, fn {_, depth} -> Integer.to_string(depth) end),
      top_level_index_range: index_range(top),
      with_description: length(with_desc),
      without_description: length(without_desc),
      no_description_task_ids: without_desc |> Enum.map(fn {task, _} -> task["id"] end) |> cap(),
      top_rank_no_comment_task_ids: flat |> top_rank_without_comments() |> cap(),
      unanchored_reference_candidates: flat |> Enum.flat_map(&reference_candidates/1) |> cap(),
      path_like_strings: flat |> Enum.flat_map(&path_like/1) |> cap(),
      journal_markers_in_descriptions: flat |> Enum.flat_map(&journal_markers/1) |> cap(),
      long_comments:
        comments
        |> Enum.filter(&long_comment?/1)
        |> Enum.map(&%{comment_id: &1["id"], task_id: &1["task_id"]})
        |> cap(),
      ai_knobs_set: present?(tree["ai_knobs"])
    }
  end

  @doc """
  Task ids whose comment threads feed the long-comment fact: the Initiative's
  root task first (its own thread — the tree read never lists the root node),
  then every tree task with a non-zero `comment_count`, in tree order.
  """
  def comment_thread_ids(tree) when is_map(tree) do
    commented =
      (Map.get(tree, "tasks") || [])
      |> flatten(0)
      |> Enum.filter(fn {task, _} -> (task["comment_count"] || 0) > 0 end)
      |> Enum.map(fn {task, _} -> task["id"] end)

    case tree["root_task_id"] do
      nil -> commented
      root_id -> [root_id | commented]
    end
  end

  defp flatten(nodes, depth) do
    Enum.flat_map(nodes, fn node ->
      [{node, depth} | flatten(children(node), depth + 1)]
    end)
  end

  defp children(task), do: Map.get(task, "children") || []

  defp index_range([]), do: nil
  defp index_range(top), do: "#{List.first(top)["index"]}..#{List.last(top)["index"]}"

  defp top_rank_without_comments(flat) do
    for {task, 0} <- flat, (task["comment_count"] || 0) == 0, do: task["id"]
  end

  defp reference_candidates({task, _depth}) do
    for field <- ["title", "description"],
        text = task[field],
        is_binary(text),
        matched <- scan_candidates(text) do
      %{task_id: task["id"], field: field, matched_text: matched}
    end
    |> Enum.uniq()
  end

  defp scan_candidates(text) do
    # Strip resolved `%<id>` tokens first — an anchored reference is exactly
    # what a candidate is not.
    stripped = Regex.replace(ref_token(), text, " ")

    Enum.flat_map(candidate_patterns(), fn pattern ->
      pattern |> Regex.scan(stripped, capture: :first) |> List.flatten()
    end)
  end

  defp path_like({task, _depth}) do
    case task["description"] do
      text when is_binary(text) ->
        path_pattern()
        |> Regex.scan(text, capture: :first)
        |> List.flatten()
        |> Enum.uniq()
        |> Enum.map(&%{task_id: task["id"], matched_text: &1})

      _ ->
        []
    end
  end

  defp journal_markers({task, _depth}) do
    case task["description"] do
      text when is_binary(text) ->
        journal_marker_pattern()
        |> Regex.scan(text, capture: :all_but_first)
        |> List.flatten()
        |> Enum.uniq()
        |> Enum.map(&%{task_id: task["id"], matched_text: &1})

      _ ->
        []
    end
  end

  defp long_comment?(comment) do
    is_binary(comment["body"]) and String.length(comment["body"]) > @long_comment_chars
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp cap(list) do
    case Enum.split(list, @cap) do
      {head, []} -> head
      {head, rest} -> head ++ ["and #{length(rest)} more"]
    end
  end
end
