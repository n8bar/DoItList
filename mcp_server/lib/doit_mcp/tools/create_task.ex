defmodule DoitMcp.Tools.CreateTask do
  @moduledoc """
  Create one task. Use `parent_id` to nest it under an existing task, or use `initiative_id` without `parent_id` to create it at the Initiative's top level. `title` and `description` accept `%<task_id>` cross-reference tokens.

  ## Repeated creation

  When a plan requires multiple task creations, always use `apply_operations`; never loop `create_task`. After too many recent creations in one Initiative, this tool refuses without creating a task and redirects you to `apply_operations`. Follow that redirect without stopping the operator; the batch path handles any required import readback. Once the readback is recorded for the Initiative this session, single creates resume.
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
    field(:done, :boolean, required: false)
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
        :position,
        :done
      ])
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    [%{"op" => "add", "type" => "task", "data" => data}]
    |> Client.operations()
    |> then(&ToolResult.reply(frame, &1))
  end

  # :pass (guardrail dark, unresolvable destination — the apply surfaces the
  # real error — or simply under pressure) or {:refuse, message}. A committed
  # create counts itself: pressure is the DATABASE's inserted_at window
  # (DoitMcp.ImportPressure), so no recording happens here.
  defp guard(params) do
    with true <- ImportGate.enabled?(),
         {:ok, target} <- destination(params),
         false <- Counter.confirmed?(target) do
      pressure = ImportPressure.recent(target)

      if pressure + 1 <= ImportGate.threshold(),
        do: :pass,
        else: {:refuse, batch_path_message(pressure)}
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
  # back: coherent one-list batches ride the ramp; one recorded readback at
  # the batch path reopens everything, singles included.
  defp batch_path_message(pressure) do
    "Nothing was created. This Initiative has #{pressure} task creations in the last #{ImportPressure.window_minutes()} minutes. Continue through `apply_operations`, one list per batch: put every task add under one parent and include no more than #{ImportGate.threshold()} task adds. Continue without asking the operator. A recent cumulative total above #{ImportGate.ramp_threshold()} requires the batch's `readback`; `apply_operations` records it as the import provenance comment. After one readback is recorded for this Initiative in the current session, single creates resume."
  end
end
