defmodule DoitMcp.Tools.CreateTask do
  @moduledoc """
  Create a task. Give `parent_id` to nest under an existing task, or
  `initiative_id` alone to create it top-level (parented to that Initiative's
  root task) — mirrors `add task` in the Arc 1 op table. `title` and
  `description` accept `%<task_id>` cross-reference tokens.

  ## Single-create pause (m03.04 3.1 iteration 2)

  The import guardrail belongs to the DESTINATION, not the tool: pressure is
  the DATABASE's recent-creation window (`DoitMcp.ImportPressure`), shared
  with the batch gate — a human-rhythm drip of creates decays out, a loop
  accumulates. Past the threshold, one-at-a-time creation pauses with an
  agent-facing redirect — users adjudicate content, never mechanism, so no
  question goes to the operator here; the batch path carries their one
  readback confirm, and coherent one-list batches ride the ramp without any.
  An initiative the operator has confirmed flows freely, singles included.
  Like the batch gate, the pause holds for every client — the batch path's
  confirm resolves in the app (m03.04 item 30), so no client capability is
  load-bearing — and rides `DOITLIST_IMPORT_GATE=off`.

  The fresh floor (m03.04 3.1 iteration 3) applies here too: a just-created
  Initiative pauses singles past `ImportGate.fresh_threshold/0` toward the
  batch path's confirm, closing the per-op dodge under the floor — an agent
  held at the floor on the batch path can't drip the rest in one at a time.
  Settling and aging out restore the normal threshold.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias DoitMcp.{Client, ImportGate, ImportPressure, ToolResult}
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
        response =
          Response.json(Response.tool(), %{
            ok: false,
            gate: "single_create_pause",
            message: message
          })

        {:reply, %{response | isError: true}, frame}

      :pass ->
        create(params, frame)
    end
  end

  defp create(params, frame) do
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

    [%{"op" => "add", "type" => "task", "data" => data}]
    |> Client.operations()
    |> then(&ToolResult.reply(frame, &1))
  end

  # :pass (guardrail dark, unresolvable destination — the apply surfaces the
  # real error — or simply under pressure) or {:refuse, message}. A committed
  # create counts itself: pressure is the DATABASE's inserted_at window
  # (DoitMcp.ImportPressure), so no recording happens here. Pressure and
  # freshness ride ONE read — the fresh floor must not double the pause's
  # per-call cost.
  defp guard(params) do
    with true <- ImportGate.enabled?(),
         {:ok, target} <- destination(params),
         false <- Counter.confirmed?(target) do
      {pressure, fresh?} = ImportPressure.recent_with_freshness(target)
      bound = if fresh?, do: ImportGate.fresh_threshold(), else: ImportGate.threshold()

      cond do
        pressure + 1 <= bound -> :pass
        fresh? -> {:refuse, fresh_floor_message(pressure)}
        true -> {:refuse, batch_path_message(pressure)}
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
  defp batch_path_message(pressure) do
    "One-at-a-time pause: #{pressure} tasks have landed in this initiative in the " <>
      "last #{ImportPressure.window_minutes()} minutes. Batch further work through " <>
      "apply_operations — one list at a time (every add under one parent, at most " <>
      "#{ImportGate.threshold()} per batch) flows without questions up to " <>
      "#{ImportGate.ramp_threshold()} recent; past that, the operator's one readback " <>
      "confirm opens this initiative fully, singles included. Nothing was created."
  end

  # The fresh floor's refusal (m03.04 3.1 iteration 3) — agent-facing only,
  # same doctrine as above: the redirect names the batch path and the one
  # operator confirm waiting there.
  defp fresh_floor_message(pressure) do
    "One-at-a-time pause: this initiative was just created (#{pressure} tasks in the " <>
      "last #{ImportPressure.window_minutes()} minutes) and its first import belongs " <>
      "on the batch path. Batch the work through apply_operations — past " <>
      "#{ImportGate.fresh_threshold()} recent adds a new initiative's import meets " <>
      "the operator's one readback confirm; their confirm opens this initiative " <>
      "fully, singles included. Nothing was created."
  end
end
