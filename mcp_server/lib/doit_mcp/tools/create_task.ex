defmodule DoitMcp.Tools.CreateTask do
  @moduledoc """
  Create a task. Give `parent_id` to nest under an existing task, or
  `initiative_id` alone to create it top-level (parented to that Initiative's
  root task) — mirrors `add task` in the Arc 1 op table. `title` and
  `description` accept `%<task_id>` cross-reference tokens.

  ## Single-create cap (m03.04 3.1 iteration 2)

  The import guardrail belongs to the DESTINATION, not the tool: every task
  this tool creates feeds the same per-initiative session counter the batch
  gate reads, and once an initiative's cumulative creates cross the gate's
  threshold, the one-at-a-time path refuses and names `apply_operations`
  (batch + readback + operator confirm) — a baseline drive, refused there,
  looped this tool to route around the gate. An initiative the operator has
  already confirmed this session flows freely, as it does for batches; like
  the batch gate, the cap stands aside for clients without elicitation
  (nothing could be confirmed there) and rides `DOITLIST_IMPORT_GATE=off`.
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
        response = Response.json(Response.tool(), %{ok: false, gate: "single_create_cap", message: message})
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
          {:refuse, cap_message(Counter.cumulative(target))}

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

  defp cap_message(cumulative) do
    "Single-create cap: this session has already created #{cumulative} tasks in this " <>
      "initiative, so the one-at-a-time path is closed. Bulk work goes through " <>
      "apply_operations — one batch with a `readback`, confirmed by the operator. Do " <>
      "not loop create_task around the import gate; nothing was created."
  end
end
