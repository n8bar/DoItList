defmodule DoItWeb.Api.TaskController do
  @moduledoc """
  The one read keyed on a bare task id (m03.04 item 2.18.1):

    * `GET /api/v1/tasks/:id` — `show`, the task → Initiative resolver.

  Exists so the MCP adapter can resolve a task-add anchored on an existing
  `parent_id` to the Initiative it grows — the import gate can't count those
  adds without it. The body is deliberately minimal (`{id, initiative_id}`,
  see `DoItWeb.Api.Serializer.task_ref/1`); the full task shape lives in the
  Initiative tree read.

  Authz deviates from the rest of the read surface on purpose: the view gate
  still runs through `DoItWeb.Api.Authz` on the task's Initiative, but every
  denial — a garbage/unknown id, a soft-deleted task, agent access off, an
  Initiative the caller can't view — is a UNIFORM 404. A bare task id must
  never be an existence oracle, so there is no 403 here to leak that the
  task exists.
  """
  use DoItWeb, :controller

  alias DoIt.Tasks
  alias DoIt.Tasks.Task
  alias DoItWeb.Api
  alias DoItWeb.Api.{Authz, Serializer}

  action_fallback DoItWeb.Api.FallbackController

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, task} <- fetch_live_task(id),
         {:ok, _initiative} <- view_gate(user, task) do
      json(conn, Api.data(Serializer.task_ref(task)))
    end
  end

  # A live task only — a garbage id, an unknown id, and a soft-deleted task
  # are all the same 404 (aligned with the rest of the read surface's
  # deleted_at: nil guard).
  defp fetch_live_task(raw_id) do
    case parse_int(raw_id) do
      nil ->
        {:error, :not_found}

      task_id ->
        case Tasks.get_task(task_id) do
          %Task{deleted_at: nil} = task -> {:ok, task}
          _ -> {:error, :not_found}
        end
    end
  end

  # Reuse Authz's whole policy (agent-access-off → 404, role check), then
  # flatten its 404-vs-403 split: a task in an Initiative the caller can't
  # view answers exactly like a task that doesn't exist.
  defp view_gate(user, %Task{initiative_id: initiative_id}) do
    case Authz.fetch_initiative(user, initiative_id, :view) do
      {:ok, initiative} -> {:ok, initiative}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_int(n) when is_integer(n), do: n
  defp parse_int(_), do: nil
end
