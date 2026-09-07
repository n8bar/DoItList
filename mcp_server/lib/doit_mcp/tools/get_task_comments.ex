defmodule DoitMcp.Tools.GetTaskComments do
  @moduledoc """
  Read one task's comments, including soft-delete tombstones. To read the Initiative's thread, use its `root_task_id` as `task_id`. Reply with `index` and `title`, never ids.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias DoitMcp.{Client, ToolResult}

  schema do
    field(:initiative_id, :integer, required: true)
    field(:task_id, :integer, required: true)
  end

  def execute(params, frame) do
    path = "/api/v1/initiatives/#{params.initiative_id}/tasks/#{params.task_id}/comments"

    case Client.get(path) do
      {:ok, data} ->
        {:reply, Response.json(ToolResult.user_content(), data), frame}

      {:error, %{status: status, body: %{"error" => error}}} ->
        {:reply, Response.error(Response.tool(), "(#{status}) #{error["message"]}"), frame}

      {:error, %{reason: reason}} ->
        {:reply, Response.error(Response.tool(), "Request failed: #{inspect(reason)}"), frame}
    end
  end
end
