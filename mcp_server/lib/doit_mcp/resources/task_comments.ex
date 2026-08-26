defmodule DoitMcp.Resources.TaskComments do
  @moduledoc """
  Read one task's comments, including soft-delete tombstones. To read the Initiative's own thread, always use its `root_task_id` as `task_id`.
  """

  use Anubis.Server.Component,
    type: :resource,
    uri_template: "doitlist://initiatives/{id}/tasks/{task_id}/comments"

  alias DoitMcp.{Client, ResourceResult}

  @impl true
  def read(%{"params" => %{"id" => id, "task_id" => task_id}}, frame) do
    frame
    |> ResourceResult.reply(Client.get("/api/v1/initiatives/#{id}/tasks/#{task_id}/comments"))
  end
end
