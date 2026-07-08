defmodule DoitMcp.Tools.GetMe do
  @moduledoc """
  Read the acting user — mirrors `GET /api/v1/me`. Tool twin of
  `DoitMcp.Resources.Me`, for agents that only look for reads in
  `tools/list`.
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.Client
  alias Anubis.Server.Response

  schema do
  end

  def execute(_params, frame) do
    case Client.get("/api/v1/me") do
      {:ok, data} ->
        {:reply, Response.json(Response.tool(), data), frame}

      {:error, %{status: status, body: %{"error" => error}}} ->
        {:reply, Response.error(Response.tool(), "(#{status}) #{error["message"]}"), frame}

      {:error, %{reason: reason}} ->
        {:reply, Response.error(Response.tool(), "Request failed: #{inspect(reason)}"), frame}
    end
  end
end
