defmodule DoItWeb.AgentConnect do
  @moduledoc """
  Composes the agent-facing MCP endpoint URL from instance config, and the
  per-client connect pastes built from it (m03.04 2.1.1.2/24.3).

  Each paste function takes the just-minted plaintext token and returns the
  full text a user pastes into their shell — self-contained: runnable as
  pasted, credential included, no assembly by the reader.
  """

  use DoItWeb, :verified_routes

  @server_name "doitlist"

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
  client, in display order. `shell` picks the wording (m03.04 2.1.2.1):
  `:posix` (default) or `:powershell`.
  """
  def client_pastes(token, shell \\ :posix)
      when is_binary(token) and shell in [:posix, :powershell] do
    [
      {"claude-code", "Claude Code", claude_code_paste(token, shell)},
      {"codex", "Codex", codex_paste(token, shell)},
      {"hermes", "Hermes Agent", hermes_paste(token, shell)}
    ]
  end

  @doc """
  Claude Code holds the credential inline, so one line does it all:
  the `mcp add` with the bearer header. Shell-neutral (25.3 audit): tokens
  are URL-safe Base64 — no `$`, backtick, or quote — so the double-quoted
  header is the same valid line in POSIX shells and PowerShell.
  """
  def claude_code_paste(token, shell \\ :posix)
      when is_binary(token) and shell in [:posix, :powershell] do
    ~s(claude mcp add --transport http #{@server_name} #{mcp_url()} --header "Authorization: Bearer #{token}")
  end

  @doc """
  Codex's config can't hold the credential — it reads an env var at launch.
  The export rides the same paste (m03.04 2.1.1.3), plus persistence so
  future shells have it too. Persistence comes BEFORE `codex mcp add`
  (m03.04 2.1.5): the add is the line that reads as success, and a reader
  who stops there must already be persisted.

  PowerShell (2.1.2.2): `$env:` sets the live session; `setx` writes the
  registry, which only shells opened fresh from the OS pick up — shells
  spawned by an already-running host (a terminal app, an editor) inherit
  the host's snapshot and never see it — so the paste also appends the
  `$env:` line to `$PROFILE` (creating its folder if missing; UTF-8, the
  Hermes paste's pattern), which every new session sources.
  """
  def codex_paste(token, shell \\ :posix)

  def codex_paste(token, :posix) when is_binary(token) do
    Enum.join(
      [
        "export DOITLIST_API_TOKEN='#{token}'",
        ~s(echo "export DOITLIST_API_TOKEN='#{token}'" >> ~/.bashrc   # or your shell's profile),
        "codex mcp add #{@server_name} --url #{mcp_url()} --bearer-token-env-var DOITLIST_API_TOKEN"
      ],
      "\n"
    )
  end

  def codex_paste(token, :powershell) when is_binary(token) do
    Enum.join(
      [
        "$env:DOITLIST_API_TOKEN = '#{token}'",
        "setx DOITLIST_API_TOKEN '#{token}'",
        "New-Item -ItemType Directory -Force (Split-Path $PROFILE) | Out-Null; " <>
          "Add-Content -Path $PROFILE -Value '$env:DOITLIST_API_TOKEN = ''#{token}''' -Encoding utf8",
        "codex mcp add #{@server_name} --url #{mcp_url()} --bearer-token-env-var DOITLIST_API_TOKEN"
      ],
      "\n"
    )
  end

  @doc """
  Hermes Agent reads the bare token (no `Bearer ` prefix) from
  `~/.hermes/.env` under the `MCP_<SERVER>_API_KEY` name — for server
  `doitlist` that's `MCP_DOITLIST_API_KEY`. The append rides the same
  paste (24.3). PowerShell (25.3): `>>` writes UTF-16 on Windows
  PowerShell 5.1, so the variant appends via `Add-Content -Encoding utf8`,
  which lands UTF-8 on both 5.1 and 7.
  """
  def hermes_paste(token, shell \\ :posix)

  def hermes_paste(token, :posix) when is_binary(token) do
    Enum.join(
      [
        "hermes mcp add #{@server_name} --url #{mcp_url()} --auth header",
        ~s(echo "MCP_DOITLIST_API_KEY=#{token}" >> ~/.hermes/.env)
      ],
      "\n"
    )
  end

  def hermes_paste(token, :powershell) when is_binary(token) do
    Enum.join(
      [
        "hermes mcp add #{@server_name} --url #{mcp_url()} --auth header",
        "Add-Content -Path ~/.hermes/.env -Value 'MCP_DOITLIST_API_KEY=#{token}' -Encoding utf8"
      ],
      "\n"
    )
  end

  @doc """
  Repo-marker snippet (m03.04 2.1.1.4), the second paste: two markdown
  lines for the repo's agent-instruction file. The URL is the whole handle —
  the Initiative's name stays in the panel's dropdown, not the paste. The URL
  composes from the endpoint's public URL config via verified routes — same
  as the API serializer's operator-facing handle.
  """
  def repo_marker(%{id: id}) do
    Enum.join(
      [
        "## Do It List",
        "Tasks: #{url(~p"/initiatives/#{id}")} — work this tree via the " <>
          "#{@server_name} MCP server, not a TODO.md or PLAN.md."
      ],
      "\n"
    )
  end
end
