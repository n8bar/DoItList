defmodule DoitMcp.Resources.InitiativeTree do
  @moduledoc """
  One Initiative's full nested task tree — mirrors `GET /api/v1/initiatives/:id`.

  Parameterized via `uri_template` (RFC 6570 Level 1 simple `{var}` expansion,
  confirmed supported by `anubis_mcp` v1.6.2 — see
  `deps/anubis_mcp/lib/anubis/server/component/resource.ex` moduledoc and
  `deps/anubis_mcp/lib/anubis/server/component/uri_template.ex`). The MCP
  server matches an incoming `resources/read` URI against `uri_template` and
  delivers the extracted variables to `read/2` as the `"params"` key of the
  first argument, e.g. `%{"uri" => uri, "params" => %{"id" => "42"}}` (see
  `deps/anubis_mcp/lib/anubis/server/handlers/resources.ex`, `read_single_resource/5`).
  """

  use Anubis.Server.Component, type: :resource, uri_template: "doitlist://initiatives/{id}"

  alias DoitMcp.{Client, ResourceResult}

  @impl true
  def read(%{"params" => %{"id" => id}}, frame) do
    frame |> ResourceResult.reply(Client.get("/api/v1/initiatives/#{id}"))
  end
end
