defmodule DoitMcp.Tools.GetInitiativeActivity do
  @moduledoc """
  Read one Initiative's activity. `task_id` scopes it to that task's subtree; `limit` and `offset` paginate — use this tool whenever either is needed. Reply with `index` and `title`, never ids.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias DoitMcp.{Client, ToolResult}

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
        {:reply, Response.json(ToolResult.user_content(), data), frame}

      {:error, %{status: status, body: %{"error" => error}}} ->
        {:reply, Response.error(Response.tool(), "(#{status}) #{error["message"]}"), frame}

      {:error, %{reason: reason}} ->
        {:reply, Response.error(Response.tool(), "Request failed: #{inspect(reason)}"), frame}
    end
  end
end
