defmodule DoitMcp.Tools.GetTaskComments do
  @moduledoc """
  Read one task's comments, including soft-delete tombstones — mirrors
  `GET /api/v1/initiatives/:id/tasks/:task_id/comments`. Tool twin of
  `DoitMcp.Resources.TaskComments`, for agents that only look for reads in
  `tools/list`.

  The Initiative's own thread is its root task's comments: to read it, pass
  `task_id` = the Initiative payload's `root_task_id`.
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.Client
  alias Anubis.Server.Response

  schema do
    field(:initiative_id, :integer, required: true)
    field(:task_id, :integer, required: true)
  end

  def execute(params, frame) do
    path = "/api/v1/initiatives/#{params.initiative_id}/tasks/#{params.task_id}/comments"

    case Client.get(path) do
      {:ok, data} ->
        {:reply, Response.json(Response.tool(), data), frame}

      {:error, %{status: status, body: %{"error" => error}}} ->
        {:reply, Response.error(Response.tool(), "(#{status}) #{error["message"]}"), frame}

      {:error, %{reason: reason}} ->
        {:reply, Response.error(Response.tool(), "Request failed: #{inspect(reason)}"), frame}
    end
  end
end
