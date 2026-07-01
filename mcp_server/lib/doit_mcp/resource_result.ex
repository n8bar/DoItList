defmodule DoitMcp.ResourceResult do
  @moduledoc """
  Shared translation from a `DoitMcp.Client.get/2` result into an MCP resource
  reply. Every resource read reduces its client call through `reply/2`.
  """

  alias Anubis.Server.Response

  def reply(frame, client_result) do
    case client_result do
      {:ok, data} ->
        {:reply, Response.json(Response.resource(), data), frame}

      {:error, %{status: status, body: %{"error" => error}}} ->
        {:reply, Response.json(Response.resource(), %{ok: false, status: status, error: error}),
         frame}

      {:error, %{reason: reason}} ->
        {:reply, Response.json(Response.resource(), %{ok: false, error: inspect(reason)}), frame}
    end
  end
end
