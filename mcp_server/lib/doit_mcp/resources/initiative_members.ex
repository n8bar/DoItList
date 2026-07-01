defmodule DoitMcp.Resources.InitiativeMembers do
  @moduledoc """
  One Initiative's members and roles — mirrors
  `GET /api/v1/initiatives/:id/members`.

  Parameterized the same way as `DoitMcp.Resources.InitiativeTree` — see that
  module's moduledoc for the `uri_template` mechanism this relies on.
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
