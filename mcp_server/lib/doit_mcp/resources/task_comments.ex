defmodule DoitMcp.Resources.TaskComments do
  @moduledoc """
  Comments on one task, including soft-delete tombstones — mirrors
  `GET /api/v1/initiatives/:id/tasks/:task_id/comments`.

  Two path variables (`id`, `task_id`) via one `uri_template` — RFC 6570
  Level 1 simple expansion supports multiple `{var}` segments separated by
  literal path components; each var's match is anchored to a single segment
  (excludes `/`, `?`, `#`), so `{id}` and `{task_id}` resolve unambiguously.
  See `DoitMcp.Resources.InitiativeTree` moduledoc for the general mechanism.
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
