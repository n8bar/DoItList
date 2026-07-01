defmodule DoitMcp.Tools.GetInitiativeActivity do
  @moduledoc """
  Read one Initiative's paginated activity rollup, optionally scoped to a
  task's subtree — mirrors `GET /api/v1/initiatives/:id/activity`.

  The equivalent resource (`DoitMcp.Resources.InitiativeActivity`) can only
  ever return the unfiltered first page: MCP resources carry no structured
  arguments, only a bare URI, and this server's URI-template support (RFC 6570
  Levels 1-2 only) can't carry an optional query tail. A tool gets a real
  input schema, so this is the only way a client can actually drive
  `task_id`/`limit`/`offset`. Read-only; it's a tool rather than a mutation
  only because that's the sole way this filtered read is reachable.
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.Client
  alias Anubis.Server.Response

  schema do
    field(:initiative_id, :integer, required: true)
    field(:task_id, :integer, required: false)
    field(:limit, :integer, required: false)
    field(:offset, :integer, required: false)
  end

  def execute(params, frame) do
    query =
      [task_id: params[:task_id], limit: params[:limit], offset: params[:offset]]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case Client.get("/api/v1/initiatives/#{params.initiative_id}/activity", query) do
      {:ok, data} ->
        {:reply, Response.json(Response.tool(), data), frame}

      {:error, %{status: status, body: %{"error" => error}}} ->
        {:reply, Response.error(Response.tool(), "(#{status}) #{error["message"]}"), frame}

      {:error, %{reason: reason}} ->
        {:reply, Response.error(Response.tool(), "Request failed: #{inspect(reason)}"), frame}
    end
  end
end
