defmodule DoitMcp.Tools.ListInitiatives do
  @moduledoc """
  List the acting user's Initiatives. Each item includes `root_task_id`, the system root task whose comments form the Initiative's thread.

  When referring the operator to an Initiative, always provide its `url` or name; never provide only its raw ID.
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
