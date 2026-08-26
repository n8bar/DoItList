defmodule DoitMcp.Tools.GetInitiativeActivity do
  @moduledoc """
  Read one Initiative's paginated activity, optionally scoped to a task's subtree. Use `task_id` to scope the subtree and `limit` with `offset` to paginate. Always use this tool when filtering or pagination is required; the equivalent resource returns only the unfiltered first page.
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
