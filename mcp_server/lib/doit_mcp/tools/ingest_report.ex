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
  in titles and descriptions; path-like strings in descriptions; whether
  `ai_knobs` is set. The reference/path scans are heuristic — expect false
  positives. Long lists carry the first 20 entries plus an `"and N more"`
  tail. Composes the same tree read as `get_initiative_tree`; the report is
  computed adapter-side (`DoitMcp.IngestReport`).
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.{Client, IngestReport}
  alias Anubis.Server.Response

  schema do
    field(:initiative_id, :integer, required: true)
  end

  def execute(params, frame) do
    case Client.get("/api/v1/initiatives/#{params.initiative_id}") do
      {:ok, data} ->
        {:reply, Response.json(Response.tool(), IngestReport.build(data)), frame}

      {:error, %{status: status, body: %{"error" => error}}} ->
        {:reply, Response.error(Response.tool(), "(#{status}) #{error["message"]}"), frame}

      {:error, %{reason: reason}} ->
        {:reply, Response.error(Response.tool(), "Request failed: #{inspect(reason)}"), frame}
    end
  end
end
