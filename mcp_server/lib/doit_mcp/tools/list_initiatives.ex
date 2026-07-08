defmodule DoitMcp.Tools.ListInitiatives do
  @moduledoc """
  List the caller's Initiatives — mirrors `GET /api/v1/initiatives`. Tool
  twin of `DoitMcp.Resources.Initiatives`, for agents that only look for
  reads in `tools/list`.
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.Client
  alias Anubis.Server.Response

  schema do
  end

  def execute(_params, frame) do
    case Client.get("/api/v1/initiatives") do
      {:ok, data} ->
        {:reply, Response.json(Response.tool(), data), frame}

      {:error, %{status: status, body: %{"error" => error}}} ->
        {:reply, Response.error(Response.tool(), "(#{status}) #{error["message"]}"), frame}

      {:error, %{reason: reason}} ->
        {:reply, Response.error(Response.tool(), "Request failed: #{inspect(reason)}"), frame}
    end
  end
end
