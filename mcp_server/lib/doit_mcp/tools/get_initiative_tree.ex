defmodule DoitMcp.Tools.GetInitiativeTree do
  @moduledoc """
  Read one Initiative's full task tree with live index labels. Always read it immediately before restructuring; collaborative changes may have invalidated an earlier read. Reply with `index` and `title`, and the Initiative `url`.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias DoitMcp.{Client, ToolResult}

  schema do
    field(:initiative_id, :integer, required: true)
  end

  def execute(params, frame) do
    case Client.get("/api/v1/initiatives/#{params.initiative_id}") do
      {:ok, data} ->
        {:reply, Response.json(ToolResult.user_content(), data), frame}

      {:error, %{status: status, body: %{"error" => error}}} ->
        {:reply, Response.error(Response.tool(), "(#{status}) #{error["message"]}"), frame}

      {:error, %{reason: reason}} ->
        {:reply, Response.error(Response.tool(), "Request failed: #{inspect(reason)}"), frame}
    end
  end
end
