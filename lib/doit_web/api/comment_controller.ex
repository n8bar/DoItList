defmodule DoItWeb.Api.CommentController do
  @moduledoc """
  Task comment reads for the `/api/v1` read surface (m03.01 worklist 2.3):

    * `GET /api/v1/initiatives/:id/tasks/:task_id/comments` — `index`.

  Nested under the Initiative so authorization is the same view check the rest of
  the read surface uses (`DoItWeb.Api.Authz.fetch_initiative/3` — 404 for an
  unknown Initiative, 403 for one the user can't view). `:task_id` must be a task
  **in that Initiative**; a foreign / unknown task id is a 404 (it isn't part of
  this tree), never a cross-Initiative leak.

  The list **includes tombstones** for soft-deleted comments (per Q6): a
  lifecycle-deleted comment surfaces as a tombstone (`deleted: true`, `body:
  null`), not omitted, so the thread shape and any references survive. Reuses
  `DoIt.Tasks.list_comments/1`, which already keeps live + tombstoned rows and
  drops only undo-removed ones. Shapes in `DoItWeb.Api.Serializer`.
  """
  use DoItWeb, :controller

  alias DoIt.Tasks
  alias DoIt.Tasks.Task
  alias DoItWeb.Api
  alias DoItWeb.Api.{Authz, Serializer}

  action_fallback DoItWeb.Api.FallbackController

  def index(conn, %{"id" => id, "task_id" => task_id}) do
    user = conn.assigns.current_user

    with {:ok, initiative} <- Authz.fetch_initiative(user, id, :view),
         {:ok, task} <- fetch_task(initiative, task_id) do
      comments = task.id |> Tasks.list_comments() |> Enum.map(&Serializer.comment/1)
      json(conn, Api.data(comments))
    end
  end

  # The task must be a LIVE task in the authorized Initiative; anything else
  # (garbage id, unknown task, a soft-deleted task, a task in another Initiative)
  # is a 404 — no cross-Initiative leak through a foreign nested id, and the
  # deleted_at: nil guard keeps the comment read aligned with the activity
  # rollup's resolve_subtree (InitiativeController), which also 404s a deleted
  # task_id.
  defp fetch_task(initiative, raw_task_id) do
    initiative_id = initiative.id

    case parse_int(raw_task_id) do
      nil ->
        {:error, :not_found}

      task_id ->
        case Tasks.get_task(task_id) do
          %Task{initiative_id: ^initiative_id, deleted_at: nil} = task -> {:ok, task}
          _ -> {:error, :not_found}
        end
    end
  end

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_int(_), do: nil
end
