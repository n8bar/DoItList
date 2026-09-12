defmodule DoitMcp.Resources.InitiativeTree do
  @moduledoc """
  Read one Initiative's current full task tree with live index labels. Always read it immediately before restructuring because collaborative changes may have invalidated an earlier read. Reply with `index` and `title`, and the Initiative `url`.
  """

  use Anubis.Server.Component, type: :resource, uri_template: "doitlist://initiatives/{id}"

  alias DoitMcp.{Client, ResourceResult}

  @impl true
  def read(%{"params" => %{"id" => id}}, frame) do
    frame |> ResourceResult.reply_user_content(Client.get("/api/v1/initiatives/#{id}"))
  end
end
