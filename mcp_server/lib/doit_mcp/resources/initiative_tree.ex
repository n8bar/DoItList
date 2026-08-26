defmodule DoitMcp.Resources.InitiativeTree do
  @moduledoc """
  Read one Initiative's current full task tree with live index labels. Always read it immediately before restructuring because collaborative changes may have invalidated an earlier read. When referring the operator to the Initiative, always provide its `url` or name; never provide only its raw ID.
  """

  use Anubis.Server.Component, type: :resource, uri_template: "doitlist://initiatives/{id}"

  alias DoitMcp.{Client, ResourceResult}

  @impl true
  def read(%{"params" => %{"id" => id}}, frame) do
    frame |> ResourceResult.reply(Client.get("/api/v1/initiatives/#{id}"))
  end
end
