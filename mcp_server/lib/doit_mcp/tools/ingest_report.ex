defmodule DoitMcp.Tools.IngestReport do
  @moduledoc """
  Mechanical lint facts about one Initiative's task tree — counts, ids, and
  matched substrings only, never verdicts. Run this after a bulk ingest or a
  bulk edit pass: it is the post-build audit's fact source (you judge each
  fact; the report only measures).

  Facts: shape (task count, depth histogram, leaf/branch counts, top-level
  index range); description coverage (with/without + ids lacking one);
  top-rank (depth 0) tasks with zero comments; un-anchored reference
  candidates (`M<n>`, dotted index paths, `task <n>` outside `%<id>` tokens)
  in titles and descriptions; path-like strings in descriptions; journal
  markers in descriptions (`Decision:`, `Verified:`, `Locked decisions:`,
  `Verification:` — journaling belongs in comments); long comments (comment
  id + task id past 300 characters, no exclusions). The text scans are
  heuristic — expect false positives. Long lists
  carry the first 20 entries plus an `"and N more"` tail. Composes the same
  tree read as `get_initiative_tree` plus the commented tasks' comment
  threads; the report is computed adapter-side (`DoitMcp.IngestReport`).
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.{Client, IngestReport}
  alias Anubis.Server.Response

  schema do
    field(:initiative_id, :integer, required: true)
  end

  def execute(params, frame) do
    with {:ok, tree} <- Client.get("/api/v1/initiatives/#{params.initiative_id}"),
         {:ok, comments} <- fetch_comments(params.initiative_id, tree) do
      {:reply, Response.json(Response.tool(), IngestReport.build(tree, comments)), frame}
    else
      {:error, %{status: status, body: %{"error" => error}}} ->
        {:reply, Response.error(Response.tool(), "(#{status}) #{error["message"]}"), frame}

      {:error, %{reason: reason}} ->
        {:reply, Response.error(Response.tool(), "Request failed: #{inspect(reason)}"), frame}
    end
  end

  # The long-comment fact needs bodies and the tree read only carries counts:
  # fetch each thread `comment_thread_ids/1` names (root task + commented
  # tasks). Any failed read fails the report — a silently partial comment
  # list would make the fact lie by omission.
  defp fetch_comments(initiative_id, tree) do
    tree
    |> IngestReport.comment_thread_ids()
    |> Enum.reduce_while({:ok, []}, fn task_id, {:ok, acc} ->
      case Client.get("/api/v1/initiatives/#{initiative_id}/tasks/#{task_id}/comments") do
        {:ok, comments} when is_list(comments) -> {:cont, {:ok, acc ++ comments}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
end
