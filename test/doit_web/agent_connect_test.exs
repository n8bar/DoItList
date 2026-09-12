defmodule DoItWeb.AgentConnectTest do
  @moduledoc """
  m03.04 2.1.1.1: `DoItWeb.AgentConnect.mcp_url/0` — both lanes: the
  `:mcp_public_url` override, and composition from the endpoint's public scheme
  and host plus `:mcp_public_port` when unset. Item 24.2/24.3: the per-client
  connect pastes — exact text, credential included, runnable as pasted. Item
  6.17: the public URL config/dev.exs composes, and the URLs clients refuse.
  `async: false`: mutates global app env and the endpoint's public URL.
  """
  use ExUnit.Case, async: false

  alias DoItWeb.AgentConnect

  setup do
    prev_url = Application.fetch_env(:doit, :mcp_public_url)
    prev_port = Application.fetch_env(:doit, :mcp_public_port)
    prev_endpoint = Application.fetch_env(:doit, DoItWeb.Endpoint)

    on_exit(fn ->
      restore_env(:mcp_public_url, prev_url)
      restore_env(:mcp_public_port, prev_port)
      restore_env(DoItWeb.Endpoint, prev_endpoint)
      reload_endpoint()
    end)

    :ok
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:doit, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:doit, key)

  # The endpoint's public URL: app env plus the cached copy the endpoint
  # actually reads.
  defp put_public_url(url) do
    config = Keyword.put(Application.get_env(:doit, DoItWeb.Endpoint), :url, url)
    Application.put_env(:doit, DoItWeb.Endpoint, config)
    reload_endpoint()
  end

  defp reload_endpoint do
    config = Application.get_env(:doit, DoItWeb.Endpoint)
    DoItWeb.Endpoint.config_change([{DoItWeb.Endpoint, config}], [])
  end

  describe "mcp_url/0 with :mcp_public_url set" do
    test "returns the override with a trailing slash added" do
      Application.put_env(:doit, :mcp_public_url, "https://mcp.example.com")
      assert AgentConnect.mcp_url() == "https://mcp.example.com/"
    end

    test "keeps an existing trailing slash single" do
      Application.put_env(:doit, :mcp_public_url, "https://mcp.example.com/")
      assert AgentConnect.mcp_url() == "https://mcp.example.com/"
    end

    test "collapses repeated trailing slashes to one" do
      Application.put_env(:doit, :mcp_public_url, "https://mcp.example.com//")
      assert AgentConnect.mcp_url() == "https://mcp.example.com/"
    end
  end

  describe "mcp_url/0 with :mcp_public_url unset" do
    test "composes http://<endpoint host>:<mcp port>/" do
      Application.delete_env(:doit, :mcp_public_url)
      Application.put_env(:doit, :mcp_public_port, 4999)
      assert AgentConnect.mcp_url() == "http://localhost:4999/"
    end

    test "treats an empty-string override as unset" do
      Application.put_env(:doit, :mcp_public_url, "")
      Application.put_env(:doit, :mcp_public_port, 4999)
      assert AgentConnect.mcp_url() == "http://localhost:4999/"
    end

    # 6.17: the scheme is the endpoint's, not a hardcoded "http" — an instance
    # published as https must not hand out a URL its clients refuse.
    test "takes the scheme from the endpoint's public URL" do
      Application.delete_env(:doit, :mcp_public_url)
      Application.put_env(:doit, :mcp_public_port, 4999)
      put_public_url(scheme: "https", host: "doitlist.example.com", port: 443)
      assert AgentConnect.mcp_url() == "https://doitlist.example.com:4999/"
    end
  end

  describe "refused_paste_url/0 (m03.04 6.17)" do
    test "names the plain-http URL a LAN host composes" do
      put_public_url(scheme: "http", host: "192.168.68.31", port: 4000)
      assert AgentConnect.refused_paste_url() == "http://192.168.68.31:4000"
    end

    test "nil for an https public URL" do
      put_public_url(scheme: "https", host: "doitlist.example.com", port: 443)
      Application.put_env(:doit, :mcp_public_url, "https://doitlist.example.com:4004")
      assert AgentConnect.refused_paste_url() == nil
    end

    test "nil on loopback, where plain http is allowed" do
      put_public_url(scheme: "http", host: "127.0.0.1", port: 4000)
      assert AgentConnect.refused_paste_url() == nil
    end

    test "catches a plain-http MCP override behind an https public URL" do
      put_public_url(scheme: "https", host: "doitlist.example.com", port: 443)
      Application.put_env(:doit, :mcp_public_url, "http://192.168.68.31:4004")
      assert AgentConnect.refused_paste_url() == "http://192.168.68.31:4004/"
    end
  end

  describe "config/dev.exs public URL (m03.04 6.17)" do
    test "PUBLIC_HOST and WEB_PORT alone compose what they always did" do
      assert dev_public_url(%{"PUBLIC_HOST" => "192.168.68.31", "WEB_PORT" => "4040"}) ==
               [scheme: "http", host: "192.168.68.31", port: 4040]
    end

    test "PUBLIC_SCHEME and PUBLIC_PORT publish a proxied https host" do
      assert dev_public_url(%{
               "PUBLIC_SCHEME" => "https",
               "PUBLIC_HOST" => "doitlist.example.com",
               "PUBLIC_PORT" => "443",
               "WEB_PORT" => "4040"
             }) == [scheme: "https", host: "doitlist.example.com", port: 443]
    end

    test "nothing set, the defaults stand" do
      assert dev_public_url(%{}) == [scheme: "http", host: "localhost", port: 4000]
    end

    test "empty strings — compose's pass-through for an unset .env var — read as unset" do
      assert dev_public_url(%{
               "PUBLIC_SCHEME" => "",
               "PUBLIC_PORT" => "",
               "WEB_PORT" => "4040"
             }) == [scheme: "http", host: "localhost", port: 4040]
    end
  end

  @public_url_vars ~w(PUBLIC_SCHEME PUBLIC_HOST PUBLIC_PORT WEB_PORT)

  # Evaluate config/dev.exs with only the given vars set — the container's own
  # environment carries these, so clear them all first, and put them back.
  defp dev_public_url(vars) do
    previous = Map.new(@public_url_vars, &{&1, System.get_env(&1)})
    Enum.each(@public_url_vars, &System.delete_env/1)
    Enum.each(vars, fn {name, value} -> System.put_env(name, value) end)

    try do
      Config.Reader.read!("config/dev.exs", env: :dev)[:doit][DoItWeb.Endpoint][:url]
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end

  describe "per-client connect pastes (items 24.2/24.3)" do
    @paste_token "doit_pat_FIXEDTESTTOKEN123"
    @paste_url "http://doit.test:4004/"

    setup do
      Application.put_env(:doit, :mcp_public_url, @paste_url)
      :ok
    end

    test "claude_code_paste/1 is one line: the add with the inline bearer header" do
      assert AgentConnect.claude_code_paste(@paste_token) ==
               "claude mcp add --transport http doitlist #{@paste_url} " <>
                 ~s(--header "Authorization: Bearer #{@paste_token}")
    end

    test "codex_paste/1 rides export, profile append, then add — persistence before the add" do
      paste = AgentConnect.codex_paste(@paste_token)

      assert paste ==
               "export DOITLIST_API_TOKEN='#{@paste_token}'\n" <>
                 ~s(echo "export DOITLIST_API_TOKEN='#{@paste_token}'" >> ~/.bashrc) <>
                 "   # or your shell's profile\n" <>
                 "codex mcp add doitlist --url #{@paste_url} " <>
                 "--bearer-token-env-var DOITLIST_API_TOKEN"

      # 2.1.1.3's bar: the credential export, the profile append, and the
      # add all in the same paste — and (2.1.5) the add LAST, so a reader
      # who stops at the line that reads as success is already persisted.
      [export_line, append_line, add_line] = String.split(paste, "\n")
      assert export_line =~ "export DOITLIST_API_TOKEN='#{@paste_token}'"
      assert append_line =~ ">> ~/.bashrc"
      assert add_line =~ "codex mcp add doitlist"
    end

    test "hermes_paste/1 appends the bare token under MCP_DOITLIST_API_KEY" do
      paste = AgentConnect.hermes_paste(@paste_token)

      assert paste ==
               "hermes mcp add doitlist --url #{@paste_url} --auth header\n" <>
                 ~s(echo "MCP_DOITLIST_API_KEY=#{@paste_token}" >> ~/.hermes/.env)

      [_add_line, env_line] = String.split(paste, "\n")
      assert env_line =~ "MCP_DOITLIST_API_KEY=#{@paste_token}"
      # Bare token: Hermes prepends the scheme itself, so no Bearer prefix here.
      refute env_line =~ "Bearer "
    end

    test "cli_paste/1 exports and persists both variables, then checks python3" do
      url = DoItWeb.Endpoint.url()
      paste = AgentConnect.cli_paste(@paste_token)

      assert paste ==
               "export DOITLIST_API_URL='#{url}'\n" <>
                 "export DOITLIST_API_TOKEN='#{@paste_token}'\n" <>
                 ~s(echo "export DOITLIST_API_URL='#{url}'" >> ~/.bashrc) <>
                 "   # or your shell's profile\n" <>
                 ~s(echo "export DOITLIST_API_TOKEN='#{@paste_token}'" >> ~/.bashrc) <>
                 "   # or your shell's profile\n" <>
                 "python3 --version   # 3.8 or newer"

      # 4.5.1's bar: BOTH variables the scripted client reads, persisted
      # before the interpreter check — the line that reads as success.
      [url_line, token_line, url_append, token_append, version_line] = String.split(paste, "\n")
      assert url_line =~ "export DOITLIST_API_URL="
      assert token_line =~ "export DOITLIST_API_TOKEN="
      assert url_append =~ ">> ~/.bashrc"
      assert token_append =~ ">> ~/.bashrc"
      assert version_line == "python3 --version   # 3.8 or newer"

      # The scripted client talks to the HTTP API, not the MCP adapter.
      refute paste =~ AgentConnect.mcp_url()
    end

    test "client_pastes/1 lists exactly the four clients, in panel order" do
      assert [
               {"claude-code", "Claude Code", _},
               {"codex", "Codex", _},
               {"hermes", "Hermes Agent", _},
               {"cli", "Scripted client (doitlist.py)", _}
             ] = AgentConnect.client_pastes(@paste_token)
    end
  end

  describe "PowerShell variants (item 25)" do
    @paste_token "doit_pat_FIXEDTESTTOKEN123"
    @paste_url "http://doit.test:4004/"

    setup do
      Application.put_env(:doit, :mcp_public_url, @paste_url)
      :ok
    end

    test "claude_code_paste/2 is shell-neutral: the PowerShell line is the POSIX line" do
      assert AgentConnect.claude_code_paste(@paste_token, :powershell) ==
               AgentConnect.claude_code_paste(@paste_token, :posix)
    end

    test "codex_paste/2 :powershell rides $env:, then setx, then add" do
      paste = AgentConnect.codex_paste(@paste_token, :powershell)

      assert paste ==
               "$env:DOITLIST_API_TOKEN = '#{@paste_token}'\n" <>
                 "setx DOITLIST_API_TOKEN '#{@paste_token}'   " <>
                 "# persists it for new shells; restart a running terminal " <>
                 "or editor so its shells see it\n" <>
                 "codex mcp add doitlist --url #{@paste_url} " <>
                 "--bearer-token-env-var DOITLIST_API_TOKEN"

      # 2.1.2.2's bar: live session via $env:, no bash-isms; 2.1.5's bar:
      # persistence that survives the shell host — the registry (setx) —
      # BEFORE the add.
      [env_line, setx_line, add_line] = String.split(paste, "\n")
      assert env_line =~ "$env:DOITLIST_API_TOKEN"
      assert setx_line =~ "setx DOITLIST_API_TOKEN"
      assert add_line =~ "codex mcp add doitlist"
      refute paste =~ "export"

      # 6.15: no $PROFILE append — Windows blocks script execution out of the
      # box, so the profile the paste wrote errored on every new shell. The
      # restart note rides the setx line as a comment, so the paste stays
      # runnable exactly as pasted.
      refute paste =~ "$PROFILE"
      refute paste =~ "New-Item"
      assert setx_line =~ "# persists it for new shells; restart"
    end

    test "hermes_paste/2 :powershell appends UTF-8 via Add-Content, not >>" do
      paste = AgentConnect.hermes_paste(@paste_token, :powershell)

      assert paste ==
               "hermes mcp add doitlist --url #{@paste_url} --auth header\n" <>
                 "Add-Content -Path ~/.hermes/.env " <>
                 "-Value 'MCP_DOITLIST_API_KEY=#{@paste_token}' -Encoding utf8"

      # 25.3: `>>` writes UTF-16 on Windows PowerShell 5.1.
      refute paste =~ ">>"
    end

    test "cli_paste/2 :powershell sets, persists via setx, then checks py -3" do
      url = DoItWeb.Endpoint.url()
      paste = AgentConnect.cli_paste(@paste_token, :powershell)

      assert paste ==
               "$env:DOITLIST_API_URL = '#{url}'\n" <>
                 "$env:DOITLIST_API_TOKEN = '#{@paste_token}'\n" <>
                 "setx DOITLIST_API_URL '#{url}'\n" <>
                 "setx DOITLIST_API_TOKEN '#{@paste_token}'\n" <>
                 "py -3 --version   # if missing: winget install --id Python.Python.3.13 -e"

      # 4.5.2's bar: the same script under py -3, no bash-isms, and the Codex
      # persistence idiom for both variables — the registry.
      assert paste =~ "py -3 --version"
      refute paste =~ "export"
      refute paste =~ "python3 --version"
      # 6.15: no $PROFILE append — it errors on every new shell.
      refute paste =~ "$PROFILE"
      refute paste =~ "New-Item"
      # 6.16: `python`/`python3` are Store stubs on a stock box, so the check
      # names the installer instead of falling back to them.
      refute paste =~ "# or: python --version"
      assert paste =~ "winget install --id Python.Python.3.13 -e"
      # 25.3: `>>` writes UTF-16 on Windows PowerShell 5.1.
      refute paste =~ ">>"
    end

    test "client_pastes/2 keeps panel order; /1 defaults to :posix" do
      assert AgentConnect.client_pastes(@paste_token) ==
               AgentConnect.client_pastes(@paste_token, :posix)

      assert [
               {"claude-code", "Claude Code", _},
               {"codex", "Codex", _},
               {"hermes", "Hermes Agent", _},
               {"cli", "Scripted client (doitlist.py)", _}
             ] = AgentConnect.client_pastes(@paste_token, :powershell)
    end
  end

  describe "repo_marker/1 (item 24.4)" do
    @marker_initiative %DoIt.Initiatives.Initiative{id: 57, name: "Q3 Launch"}

    test "exact two-line markdown snippet — the URL is the whole handle" do
      expected_url = DoItWeb.Endpoint.url() <> "/initiatives/57"

      assert AgentConnect.repo_marker(@marker_initiative) ==
               "## Do It List\n" <>
                 "Tasks: #{expected_url} — work this tree via the doitlist " <>
                 "MCP server, not a TODO.md or PLAN.md."
    end

    test "the Initiative's name stays out of the paste — the dropdown carries it" do
      refute AgentConnect.repo_marker(@marker_initiative) =~ "Q3 Launch"
    end

    test "the id appears only inside the URL path — no bare id leakage" do
      marker = AgentConnect.repo_marker(@marker_initiative)

      assert marker =~ "/initiatives/57"
      # The URL path segment is the id's ONLY occurrence — no "ID: 57" style.
      assert Regex.scan(~r/57/, marker) == [["57"]]
      refute marker =~ ~r/\bid\b/i
    end
  end
end
