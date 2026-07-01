defmodule DoitMcp.ToolResult do
  @moduledoc """
  Shared translation from a `DoitMcp.Client.operations/1` result into an MCP
  tool reply. Every granular tool builds a one-op batch and reduces it through
  `reply/2`; `apply_operations` (the batch mirror) uses `reply_batch/2` to pass
  the full per-op results list through untouched.
  """

  alias Anubis.Server.Response

  @doc "Reply for a batch of exactly one op — the shape every granular tool shares."
  def reply(frame, client_result) do
    case client_result do
      {:ok, %{"results" => [%{"status" => "ok"} = result]}} ->
        {:reply, Response.json(Response.tool(), Map.get(result, "data", %{})), frame}

      {:ok, %{"results" => [%{"status" => "error", "error" => op_error} | _]}} ->
        {:reply, Response.error(Response.tool(), op_error["message"]), frame}

      {:error, %{status: status, body: %{"error" => error}}} ->
        {:reply, Response.error(Response.tool(), "(#{status}) #{error["message"]}"), frame}

      {:error, %{reason: reason}} ->
        {:reply, Response.error(Response.tool(), "Request failed: #{inspect(reason)}"), frame}
    end
  end

  @doc """
  Reply for `apply_operations` — passes the full ordered results list through
  as JSON. A rolled-back batch still sets `isError: true` (on top of the JSON
  payload) so a client that only checks the protocol-level error flag doesn't
  mistake a failed/rolled-back batch for a success.
  """
  def reply_batch(frame, client_result) do
    case client_result do
      {:ok, %{"results" => results}} ->
        {:reply, Response.json(Response.tool(), %{ok: true, results: results}), frame}

      {:error, %{status: status, body: %{"error" => error, "results" => results}}} ->
        response =
          Response.tool()
          |> Response.json(%{ok: false, status: status, error: error, results: results})

        {:reply, %{response | isError: true}, frame}

      {:error, %{status: status, body: %{"error" => error}}} ->
        response = Response.json(Response.tool(), %{ok: false, status: status, error: error})
        {:reply, %{response | isError: true}, frame}

      {:error, %{reason: reason}} ->
        {:reply, Response.error(Response.tool(), "Request failed: #{inspect(reason)}"), frame}
    end
  end
end
