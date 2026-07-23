defmodule DoitMcp.Tools.CreateTask do
  @moduledoc """
  Create a task. Give `parent_id` to nest under an existing task, or
  `initiative_id` alone to create it top-level (parented to that Initiative's
  root task) — mirrors `add task` in the Arc 1 op table. `title` and
  `description` accept `%<task_id>` cross-reference tokens.

  ## Single-create pause (m03.04 3.1 iteration 2)

  The import guardrail belongs to the DESTINATION, not the tool: every task
  this tool creates feeds the same per-initiative session counter the batch
  gate reads. Past the gate's threshold, one-at-a-time creation pauses with
  an agent-facing redirect — users adjudicate content, never mechanism, so
  no question goes to the operator here; the batch path carries their one
  readback confirm, and coherent one-list batches ride the ramp without any.
  An initiative the operator has confirmed flows freely, singles included.
  Like the batch gate, the pause stands aside for clients without
  elicitation and rides `DOITLIST_IMPORT_GATE=off`.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias DoitMcp.{Client, Elicitation, ImportGate, ToolResult}
  alias DoitMcp.ImportGate.Counter

  schema do
    field(:initiative_id, :integer, required: false)
    field(:parent_id, :integer, required: false)
    field(:title, :string, required: true)
    field(:description, :string, required: false)
    field(:priority, :string, required: false)
    field(:assignee_id, :integer, required: false)
    field(:manual_progress, :integer, required: false)
    field(:position, :integer, required: false)
  end

  def execute(params, frame) do
    case guard(params) do
      {:refuse, message} ->
        response = Response.json(Response.tool(), %{ok: false, gate: "single_create_pause", message: message})
        {:reply, %{response | isError: true}, frame}

      record ->
        create(params, record, frame)
    end
  end

  defp create(params, record, frame) do
    data =
      params
      |> Map.take([
        :initiative_id,
        :parent_id,
        :title,
        :description,
        :priority,
        :assignee_id,
        :manual_progress,
        :position
      ])
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    result = Client.operations([%{"op" => "add", "type" => "task", "data" => data}])

    # A committed create counts toward the shared session counter, so thirty
    # singles and a thirty-add batch read as the same import pressure.
    with {:ok, _body} <- result,
         {:record, target} <- record do
      Counter.record([{target, 1}])
    end

    ToolResult.reply(frame, result)
  end

  # :pass (guardrail dark, or unresolvable destination — the apply surfaces
  # the real error), {:record, target}, or {:refuse, message}.
  defp guard(params) do
    with true <- ImportGate.enabled?() and Elicitation.client_supports_elicitation?(),
         {:ok, target} <- destination(params) do
      cond do
        Counter.confirmed?(target) ->
          {:record, target}

        Counter.cumulative(target) + 1 > ImportGate.threshold() ->
          {:refuse, batch_path_message(Counter.cumulative(target))}

        true ->
          {:record, target}
      end
    else
      _ -> :pass
    end
  end

  defp destination(%{initiative_id: iid}) when is_integer(iid), do: {:ok, {:existing, iid}}

  defp destination(%{parent_id: pid}) when is_integer(pid) do
    case Client.get("/api/v1/tasks/#{pid}") do
      {:ok, %{"initiative_id" => iid}} -> {:ok, {:existing, iid}}
      _ -> :error
    end
  end

  defp destination(_params), do: :error

  # Agent-facing only — never a question to the operator. Names the path
  # back: coherent one-list batches ride the ramp; one operator confirm at
  # the batch gate reopens everything, singles included.
  defp batch_path_message(cumulative) do
    "One-at-a-time pause: #{cumulative} tasks have landed in this initiative this " <>
      "session. Batch further work through apply_operations — one list at a time " <>
      "(every add under one parent, at most #{ImportGate.threshold()} per batch) " <>
      "flows without questions up to #{ImportGate.ramp_threshold()} cumulative; past " <>
      "that, the operator's one readback confirm opens this initiative fully, singles " <>
      "included. Nothing was created."
  end
end
