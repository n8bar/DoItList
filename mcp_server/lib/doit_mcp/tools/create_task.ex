defmodule DoitMcp.Tools.CreateTask do
  @moduledoc """
  Create a task. Give `parent_id` to nest under an existing task, or
  `initiative_id` alone to create it top-level (parented to that Initiative's
  root task) — mirrors `add task` in the Arc 1 op table. `title` and
  `description` accept `%<task_id>` cross-reference tokens.

  ## Single-create continuation confirm (m03.04 3.1 iteration 2)

  The import guardrail belongs to the DESTINATION, not the tool: every task
  this tool creates feeds the same per-initiative session counter the batch
  gate reads. Crossing the gate's threshold one-by-one ASKS the operator —
  quantity can't tell an import loop from live co-creation, but the operator
  can: approve sanctions the session (the same confirm memory the batch gate
  honors), decline latches and later attempts refuse toward
  `apply_operations` without re-asking. A baseline drive, refused at the
  batch gate, looped this tool to route around it — that path now resolves
  at the operator too. Like the batch gate, the confirm stands aside for
  clients without elicitation and rides `DOITLIST_IMPORT_GATE=off`.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias DoitMcp.{Client, Elicitation, ImportGate, ToolResult}
  alias DoitMcp.ImportGate.Counter

  # A human is reading one question — same generous window as the other gates.
  @confirm_timeout to_timeout(minute: 5)

  @confirm_schema %{
    "type" => "object",
    "properties" => %{
      "approve" => %{
        "type" => "boolean",
        "description" =>
          "true sanctions continuing one-by-one in this initiative for the session; " <>
            "false stops it (bulk work then goes through apply_operations)"
      }
    },
    "required" => ["approve"]
  }

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
        response = Response.json(Response.tool(), %{ok: false, gate: "single_create_confirm", message: message})
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

        Counter.cumulative(target) + 1 <= ImportGate.threshold() ->
          {:record, target}

        Counter.declined?(target) ->
          {:refuse, declined_message()}

        true ->
          confirm_continuation(target, Counter.cumulative(target))
      end
    else
      _ -> :pass
    end
  end

  # Quantity only triggers the ask — the operator is the differentiator
  # between an import loop and live co-creation; the server can't see the
  # conversation. Approve settles the session (same memory the batch gate
  # honors); decline latches so a persistent loop can't re-ask.
  defp confirm_continuation(target, cumulative) do
    case Elicitation.request(confirm_message(cumulative), @confirm_schema, @confirm_timeout) do
      {:ok, %{"action" => "accept", "content" => %{"approve" => true}}} ->
        Counter.mark_confirmed(target)
        {:record, target}

      {:ok, %{"action" => _declined_or_disapproved}} ->
        Counter.mark_declined(target)
        {:refuse, declined_message()}

      {:error, _timeout_no_session_or_busy} ->
        {:refuse,
         "Asked the operator whether to keep creating tasks one-by-one here but got no " <>
           "answer — nothing was created. Retry when they're available, or batch the " <>
           "work through apply_operations."}
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

  defp confirm_message(cumulative) do
    "The agent has created #{cumulative} tasks one-by-one in this initiative this " <>
      "session. If you're building these together, approve — you won't be asked again " <>
      "here this session. If you didn't ask for this volume, decline: an import belongs " <>
      "in one apply_operations batch you confirm as a whole."
  end

  defp declined_message do
    "The operator declined continuing one-by-one in this initiative — not asking " <>
      "again this session. Bulk work goes through apply_operations (one batch with a " <>
      "`readback`, confirmed by the operator); nothing was created."
  end
end
