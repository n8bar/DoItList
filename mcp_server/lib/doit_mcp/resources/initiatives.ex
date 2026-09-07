defmodule DoitMcp.Resources.Initiatives do
  @moduledoc """
  List the acting user's Initiatives. Each item includes `root_task_id`, the system root task whose comments form the Initiative's thread. Reply with the Initiative `url`, never its id.
  """

  use Anubis.Server.Component, type: :resource, uri: "doitlist://initiatives"

  alias DoitMcp.{Client, ResourceResult}

  @impl true
  def read(_params, frame) do
    frame |> ResourceResult.reply_user_content(Client.get("/api/v1/initiatives"))
  end
end
