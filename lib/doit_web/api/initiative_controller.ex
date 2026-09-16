defmodule DoItWeb.Api.InitiativeController do
  @moduledoc """
  The Initiative-scoped read endpoints of the `/api/v1` read surface (m03.01
  worklist 2):

    * `GET /api/v1/initiatives` — `index`, the acting user's Initiatives.
    * `GET /api/v1/initiatives/:id` — `show`, the whole nested task tree.
    * `GET /api/v1/initiatives/:id/activity` — `activity`, the paginated
      activity rollup (subtree-scoped with `?task_id=`).
    * `GET /api/v1/initiatives/:id/members` — `members`, members with roles.

  Every endpoint reads through `DoItWeb.Api.Authz` — a user only ever sees an
  Initiative they can **view**. The 404-vs-403 policy lives in
  `Authz.fetch_initiative/3`: an unknown/garbage id → 404, an existing Initiative
  the user can't view → 403 (the stranger case). The shapes are documented and
  built in `DoItWeb.Api.Serializer`.
  """
  use DoItWeb, :controller

  alias DoIt.{Initiatives, Tasks}
  alias DoIt.Tasks.Task
  alias DoItWeb.Api
  alias DoItWeb.Api.{Authz, Errors, Reads, Serializer}

  action_fallback DoItWeb.Api.FallbackController

  @doc """
  List the Initiatives the acting user belongs to. No per-Initiative authz: the
  query is already scoped to their memberships. Filtered to agent-accessible
  Initiatives (m03.04 2.4.1.2) — a flagged-off one never appears, matching
  the 404 its direct reads return.
  """
  def index(conn, _params) do
    user = conn.assigns.current_user
    json(conn, Api.data(Reads.initiative_summaries(user, agent_access_only: true)))
  end

  @doc "The whole nested Initiative tree in one response."
  def show(conn, %{"id" => id}) do
    with {:ok, payload} <- Reads.initiative_tree(conn.assigns.current_user, id) do
      json(conn, Api.data(payload))
    end
  end

  @doc """
  One Initiative's activity, newest first. Paginated, and `?task_id=` scopes to
  that task's subtree; `?limit=` / `?offset=`
  page (limit clamped 1..200, default 50). A foreign/unknown `task_id` → 404.
  """
  def activity(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user

    with {:ok, initiative} <- Authz.fetch_initiative(user, id, :view),
         {:ok, task_ids, task_id} <- resolve_subtree(initiative, params["task_id"]) do
      opts =
        [
          limit: parse_int(params["limit"]),
          offset: parse_int(params["offset"]),
          task_ids: task_ids
        ]
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)

      %{events: events, limit: limit, offset: offset, has_more: has_more} =
        Tasks.list_initiative_activity(initiative.id, opts)

      meta = %{
        limit: limit,
        offset: offset,
        has_more: has_more,
        next_offset: if(has_more, do: offset + limit, else: nil),
        scope: %{initiative_id: initiative.id, task_id: task_id}
      }

      json(conn, Api.data(Enum.map(events, &Serializer.activity_event/1), meta))
    end
  end

  @doc "The Initiative's members with their roles."
  def members(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, initiative} <- Authz.fetch_initiative(user, id, :view) do
      members = initiative.id |> Initiatives.list_members() |> Enum.map(&Serializer.member/1)
      json(conn, Api.data(members))
    end
  end

  @doc """
  How many Tasks an Initiative has. Dumb facts for a caller sizing up a tree,
  alongside its name, creation instant, and index style (the system root
  excluded): `?created_at=<ISO8601>` scopes `count` and `done_count` to tasks
  created at or after that instant, while `live_count` always covers the whole
  live tree.
  """
  def task_count(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user

    with {:ok, initiative} <- Authz.fetch_initiative(user, id, :view) do
      case parse_created_at(Map.get(params, "created_at")) do
        {:ok, created_at} ->
          json(
            conn,
            Api.data(%{
              count: Tasks.count_created(initiative.id, created_at),
              done_count: Tasks.count_created_done(initiative.id, created_at),
              live_count: Tasks.count_created(initiative.id),
              initiative_created_at: DateTime.to_iso8601(initiative.inserted_at),
              initiative_index_style: initiative.index_style,
              initiative_name: initiative.name
            })
          )

        :error ->
          Errors.send_error(
            conn,
            422,
            :unprocessable_entity,
            "created_at must be an ISO 8601 datetime, e.g. 2026-07-23T17:00:00Z."
          )
      end
    end
  end

  defp parse_created_at(nil), do: {:ok, nil}

  defp parse_created_at(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> :error
    end
  end

  # No `task_id` → whole-Initiative rollup (task_ids nil, scope task_id nil).
  # A `task_id` → validate it's a live task in THIS Initiative, then scope to its
  # subtree ids; a foreign / unknown one is a 404 (it isn't part of this tree).
  defp resolve_subtree(_initiative, nil), do: {:ok, nil, nil}

  defp resolve_subtree(initiative, raw_task_id) do
    initiative_id = initiative.id

    case parse_int(raw_task_id) do
      nil ->
        {:error, :not_found}

      task_id ->
        case Tasks.get_task(task_id) do
          %Task{initiative_id: ^initiative_id, deleted_at: nil} = task ->
            {:ok, Tasks.subtree_ids(task.id), task.id}

          _ ->
            {:error, :not_found}
        end
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(n) when is_integer(n), do: n

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end
end
