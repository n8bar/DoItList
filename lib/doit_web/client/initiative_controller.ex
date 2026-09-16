defmodule DoItWeb.Client.InitiativeController do
  @moduledoc """
  The browser client's Initiative reads (m04.01 worklist 5):

    * `GET /app/api/initiatives` — the index list.
    * `GET /app/api/initiatives/:id` — the whole nested tree.

  Both are one call into `DoItWeb.Api.Reads`, which the `/api/v1` controller
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

  @doc "The whole nested Initiative tree."
  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, payload} <- Reads.initiative_tree(user, id, require_agent_access: false) do
      json(conn, Api.data(payload))
    end
  end
end
