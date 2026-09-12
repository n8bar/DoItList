defmodule DoitMcp.Resources.InitiativeMembers do
  @moduledoc """
  Read one Initiative's members and roles.
  """

  use Anubis.Server.Component,
    type: :resource,
    uri_template: "doitlist://initiatives/{id}/members"

  alias DoitMcp.{Client, ResourceResult}

  @impl true
  def read(%{"params" => %{"id" => id}}, frame) do
    frame |> ResourceResult.reply(Client.get("/api/v1/initiatives/#{id}/members"))
  end
end
