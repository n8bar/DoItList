defmodule DoitMcp.Resources.InitiativeActivity do
  @moduledoc """
  One Initiative's paginated activity rollup, optionally scoped to a task's
  subtree — mirrors `GET /api/v1/initiatives/:id/activity`.

  ## URI parameters — what's real vs. what's wired-but-inert

  `id` is a genuine `uri_template` path variable (see
  `DoitMcp.Resources.InitiativeTree` moduledoc for the mechanism): the MCP
  server matches the requested URI against `uri_template` and delivers `id`
  to `read/2` via `params["id"]`.

  The optional `task_id`/`limit`/`offset` filters are a different story. MCP's
  `resources/read` request carries only a bare `uri` — there is no separate
  structured-arguments channel for resources the way there is for tools
  (`Anubis.Server.Component`'s `schema do ... end` macro only wires
  `input_schema`/arguments for `:tool` and `:prompt` components, not
  `:resource`; see `deps/anubis_mcp/lib/anubis/server/component.ex`). The
  usual place these would ride is an RFC 6570 Level 3 query-string template
  (`{?task_id,limit,offset}`), but `anubis_mcp` v1.6.2's `URITemplate` only
  implements Levels 1-2 and explicitly documents Level 3 (query) as
  unsupported (`deps/anubis_mcp/lib/anubis/server/component/uri_template.ex`
  moduledoc). A single static template also can't optionally match "with
  suffix" and "without suffix" URIs, since every declared template variable
  requires at least one captured character (`([^#]+)` for `{+var}`, never
  zero-width) — so there is no way to bolt an optional query tail onto
  `uri_template: "doitlist://initiatives/{id}/activity"` without breaking the
  plain (unfiltered) URI that every client will use by default.

  Given that, this resource only accepts `id` for now — `task_id`, `limit`,
  and `offset` are NOT reachable through a real MCP `resources/read` call in
  this version. The `read/2` body below still builds the outbound query from
  those keys (present-only) so the shape is correct and forward-compatible,
  but under the current `uri_template` they will always be absent. If
  per-task-subtree/paginated activity needs to be client-driven, it should be
  exposed as an MCP *tool* instead (tools get a real `input_schema`), not
  bolted onto this resource.
  """

  use Anubis.Server.Component,
    type: :resource,
    uri_template: "doitlist://initiatives/{id}/activity"

  alias DoitMcp.{Client, ResourceResult}

  @impl true
  def read(%{"params" => %{"id" => id} = vars}, frame) do
    query =
      [
        task_id: Map.get(vars, "task_id"),
        limit: Map.get(vars, "limit"),
        offset: Map.get(vars, "offset")
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    frame |> ResourceResult.reply(Client.get("/api/v1/initiatives/#{id}/activity", query))
  end
end
