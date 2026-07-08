defmodule DoitMcp.Tools.GetInitiativeMembers do
  @moduledoc """
  Read one Initiative's members and roles — mirrors
  `GET /api/v1/initiatives/:id/members`. Tool twin of
  `DoitMcp.Resources.InitiativeMembers`, for agents that only look for reads
  in `tools/list`.
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.Client
  alias Anubis.Server.Response

  schema do
    field(:initiative_id, :integer, required: true)
  end

  def execute(params, frame) do
    case Client.get("/api/v1/initiatives/#{params.initiative_id}/members") do
      {:ok, data} ->
        {:reply, Response.json(Response.tool(), data), frame}

      {:error, %{status: status, body: %{"error" => error}}} ->
        {:reply, Response.error(Response.tool(), "(#{status}) #{error["message"]}"), frame}

      {:error, %{reason: reason}} ->
        {:reply, Response.error(Response.tool(), "Request failed: #{inspect(reason)}"), frame}
    end
  end
end
