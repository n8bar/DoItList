defmodule DoitMcp.Resources.Initiatives do
  @moduledoc """
  List the acting user's Initiatives. Each item includes `root_task_id`, the system root task whose comments form the Initiative's thread. When referring the operator to an Initiative, always provide its `url` or name; never provide only its raw ID.
  """

  use Anubis.Server.Component, type: :resource, uri: "doitlist://initiatives"

  alias DoitMcp.{Client, ResourceResult}

  @impl true
  def read(_params, frame) do
    frame |> ResourceResult.reply(Client.get("/api/v1/initiatives"))
  end
end
