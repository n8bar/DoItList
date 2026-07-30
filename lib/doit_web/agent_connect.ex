defmodule DoItWeb.AgentConnect do
  @moduledoc """
  Composes the agent-facing MCP endpoint URL from instance config, and the
  per-client connect pastes built from it (m03.04 item 24.2/24.3).

  Each paste function takes the just-minted plaintext token and returns the
  full text a user pastes into their shell — self-contained: runnable as
  pasted, credential included, no assembly by the reader.
  """

  use DoItWeb, :verified_routes

  @server_name "doit-list"

  @doc """
  The public URL agents connect to, with exactly one trailing slash.

  `:mcp_public_url` (full override, for scheme/port differences like hosted
  TLS) wins; otherwise the web endpoint's public host plus `:mcp_public_port`
  compose it.
  """
  def mcp_url do
    case Application.get_env(:doit, :mcp_public_url) do
      v when v in [nil, ""] ->
        host = DoItWeb.Endpoint.struct_url().host
        port = Application.get_env(:doit, :mcp_public_port, 4004)
        "http://#{host}:#{port}/"

      url ->
        String.trim_trailing(url, "/") <> "/"
    end
  end

  @doc """
  All connect pastes for the panel: `{dom_slug, client_name, paste}` per
  client, in display order.
  """
  def client_pastes(token) when is_binary(token) do
    [
      {"claude-code", "Claude Code", claude_code_paste(token)},
      {"codex", "Codex", codex_paste(token)},
      {"hermes", "Hermes Agent", hermes_paste(token)}
    ]
  end

  @doc """
  Claude Code holds the credential inline, so one line does it all:
  the `mcp add` with the bearer header.
  """
  def claude_code_paste(token) when is_binary(token) do
    ~s(claude mcp add --transport http #{@server_name} #{mcp_url()} --header "Authorization: Bearer #{token}")
  end

  @doc """
  Codex's config can't hold the credential — it reads an env var at launch.
  The export rides the same paste (24.3), plus a profile append so future
  shells have it too.
  """
  def codex_paste(token) when is_binary(token) do
    Enum.join(
      [
        "export DOITLIST_API_TOKEN='#{token}'",
        "codex mcp add #{@server_name} --url #{mcp_url()} --bearer-token-env-var DOITLIST_API_TOKEN",
        ~s(echo "export DOITLIST_API_TOKEN='#{token}'" >> ~/.bashrc   # or your shell's profile)
      ],
      "\n"
    )
  end

  @doc """
  Hermes Agent reads the bare token (no `Bearer ` prefix) from
  `~/.hermes/.env` under the `MCP_<SERVER>_API_KEY` name — for server
  `doit-list` that's `MCP_DOIT_LIST_API_KEY`. The append rides the same
  paste (24.3).
  """
  def hermes_paste(token) when is_binary(token) do
    Enum.join(
      [
        "hermes mcp add #{@server_name} --url #{mcp_url()} --auth header",
        ~s(echo "MCP_DOIT_LIST_API_KEY=#{token}" >> ~/.hermes/.env)
      ],
      "\n"
    )
  end

  @doc """
  Repo-marker snippet (m03.04 item 24.4), the second paste: a few markdown
  lines for the repo's agent-instruction file naming the Initiative and its
  web URL, so a connected agent works the tree instead of starting a
  `TODO.md`. The URL composes from the endpoint's public URL config via
  verified routes — same as the API serializer's operator-facing handle.
  """
  def repo_marker(%{name: name, id: id}) do
    Enum.join(
      [
        "## Do It List",
        ~s(This repo's work is tracked in the "#{name}" Initiative: #{url(~p"/initiatives/#{id}")}),
        "Use the #{@server_name} MCP server to read and work that task tree — " <>
          "plan from it and record progress there instead of a TODO.md."
      ],
      "\n"
    )
  end
end
