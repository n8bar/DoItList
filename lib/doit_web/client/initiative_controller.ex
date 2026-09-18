defmodule DoItWeb.Client.InitiativeController do
  @moduledoc """
  The browser client's Initiative reads (m04.01 worklist 5):

    * `GET /app/api/initiatives` — the index list.
    * `GET /app/api/initiatives/archive` — the Archived and Trash drawer's rows.
    * `GET /app/api/initiatives/:id` — the whole nested tree.
    * `GET /app/api/initiatives/:id/members` — members with their roles.
    * `GET /app/api/initiatives/:id/history` — what this user can undo / redo.

  Each is one call into `DoItWeb.Api.Reads`, which the `/api/v1` controller
  calls too — same contexts, same `DoItWeb.Api.Authz` gate (unknown id → 404,
  can't view → 403), same `DoItWeb.Api.Serializer` shapes. The single
  difference is the agent-access flag: this surface passes
  `require_agent_access: false`, because the per-Initiative checkbox gates
  agents, not a member reading their own Initiative in a browser.
  """
  use DoItWeb, :controller

  alias DoItWeb.Api
  alias DoItWeb.Api.Reads

  action_fallback DoItWeb.Client.FallbackController

  @doc "Every Initiative the signed-in user can see."
  def index(conn, _params) do
    json(conn, Api.data(Reads.initiative_summaries(conn.assigns.current_user)))
  end

  @doc """
  What this user has put away: `archived`, their own archived and hidden
  Initiatives, and `trashed`, the ones they own that sit in Trash (m04.02 item
  4.5). Scoped to the user like the index, so no per-Initiative authz.
  """
  def archive(conn, _params) do
    json(conn, Api.data(Reads.initiative_archive(conn.assigns.current_user)))
  end

  @doc "The whole nested Initiative tree."
  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, payload} <- Reads.initiative_tree(user, id, require_agent_access: false) do
      json(conn, Api.data(payload))
    end
  end

  @doc "The Initiative's members with their roles — who the client draws avatars for."
  def members(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, members} <- Reads.initiative_members(user, id, require_agent_access: false) do
      json(conn, Api.data(members))
    end
  end

  @doc """
  What the signed-in user can undo and redo here, each `%{"label" => …}` or
  `null` — the toolbar's two buttons, per-user and session-only.
  """
  def history(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, payload} <- Reads.initiative_history(user, id, require_agent_access: false) do
      json(conn, Api.data(payload))
    end
  end
end
