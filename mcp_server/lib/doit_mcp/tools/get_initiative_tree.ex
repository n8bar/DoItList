defmodule DoitMcp.Tools.GetInitiativeTree do
  @moduledoc """
  Read one Initiative's current full task tree with live index labels. Always call this immediately before restructuring because collaborative changes may have invalidated an earlier read.

  When referring the operator to the Initiative, always provide its `url` or name; never provide only its raw ID.
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.Client
  alias Anubis.Server.Response

  schema do
    field(:initiative_id, :integer, required: true)
  end

  def execute(params, frame) do
    case Client.get("/api/v1/initiatives/#{params.initiative_id}") do
      {:ok, data} ->
        {:reply, Response.json(Response.tool(), data), frame}

      {:error, %{status: status, body: %{"error" => error}}} ->
        {:reply, Response.error(Response.tool(), "(#{status}) #{error["message"]}"), frame}

      {:error, %{reason: reason}} ->
        {:reply, Response.error(Response.tool(), "Request failed: #{inspect(reason)}"), frame}
    end
  end
end
