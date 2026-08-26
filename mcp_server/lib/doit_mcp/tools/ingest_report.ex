defmodule DoitMcp.Tools.IngestReport do
  @moduledoc """
  Run after every bulk ingest or edit pass. This tool reports mechanical lint facts about one Initiative's task tree, never verdicts. Always determine whether each fact is an issue from the source intent and current tree before changing anything.

  Reports task count, depth histogram, leaf and branch counts, top-level index range, description coverage and missing-description IDs, uncommented top-level tasks, path-like description strings, and heuristic text matches. Matches include unanchored references (`M<n>`, dotted indexes, or `task <n>` outside `%<id>` tokens), description journal markers (`Decision:`, `Verified:`, `Locked decisions:`, or `Verification:`), and every comment over 300 characters. Match lists include the first 20 entries plus an `"and N more"` count.
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
