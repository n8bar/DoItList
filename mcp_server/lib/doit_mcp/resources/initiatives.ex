defmodule DoitMcp.Resources.Initiatives do
  @moduledoc "The caller's Initiatives — mirrors `GET /api/v1/initiatives`."

  use Anubis.Server.Component, type: :resource, uri: "doitlist://initiatives"

  alias DoitMcp.{Client, ResourceResult}

  @impl true
  def read(_params, frame) do
    frame |> ResourceResult.reply(Client.get("/api/v1/initiatives"))
  end
end
