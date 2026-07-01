defmodule DoitMcp.Resources.Me do
  @moduledoc "The acting user — mirrors `GET /api/v1/me`."

  use Anubis.Server.Component, type: :resource, uri: "doitlist://me"

  alias DoitMcp.{Client, ResourceResult}

  @impl true
  def read(_params, frame) do
    frame |> ResourceResult.reply(Client.get("/api/v1/me"))
  end
end
