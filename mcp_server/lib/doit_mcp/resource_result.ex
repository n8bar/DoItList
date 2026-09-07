defmodule DoitMcp.ResourceResult do
  @moduledoc """
  Shared translation from a `DoitMcp.Client.get/2` result into an MCP resource
  reply. Every resource read reduces its client call through `reply/2`, or
  through `reply_user_content/2` when the payload carries user-written titles,
  descriptions, or comments (m03.04 3.5.1). A resource's content is one text
  blob, so the marker rides as its first line rather than as its own block.
  """

  alias Anubis.Server.Response
  alias DoitMcp.ToolResult

  @doc "Resource reply for a payload that carries no user-written text."
  def reply(frame, client_result), do: respond(frame, client_result, "")

  @doc "Resource reply for a payload carrying titles, descriptions, or comments."
  def reply_user_content(frame, client_result),
    do: respond(frame, client_result, ToolResult.user_content_line() <> "\n")

  defp respond(frame, client_result, prefix) do
    case client_result do
      {:ok, data} ->
        {:reply, Response.text(Response.resource(), prefix <> JSON.encode!(data)), frame}

      {:error, %{status: status, body: %{"error" => error}}} ->
        {:reply, Response.json(Response.resource(), %{ok: false, status: status, error: error}),
         frame}

      {:error, %{reason: reason}} ->
        {:reply, Response.json(Response.resource(), %{ok: false, error: inspect(reason)}), frame}
    end
  end
end
