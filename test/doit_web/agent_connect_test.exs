defmodule DoItWeb.AgentConnectTest do
  @moduledoc """
  m03.04 2.1.1.1: `DoItWeb.AgentConnect.mcp_url/0` — both lanes: the
  `:mcp_public_url` override, and composition from the endpoint's public host
  plus `:mcp_public_port` when unset. Item 24.2/24.3: the per-client connect
  pastes — exact text, credential included, runnable as pasted.
  `async: false`: mutates global app env.
  """
  use ExUnit.Case, async: false

  alias DoItWeb.AgentConnect

  setup do
    prev_url = Application.fetch_env(:doit, :mcp_public_url)
    prev_port = Application.fetch_env(:doit, :mcp_public_port)

    on_exit(fn ->
      restore_env(:mcp_public_url, prev_url)
      restore_env(:mcp_public_port, prev_port)
    end)

    :ok
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:doit, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:doit, key)

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

    test "client_pastes/1 lists exactly the three clients, in panel order" do
      assert [
               {"claude-code", "Claude Code", _},
               {"codex", "Codex", _},
               {"hermes", "Hermes Agent", _}
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

    test "codex_paste/2 :powershell rides $env:, setx, $PROFILE append, then add" do
      paste = AgentConnect.codex_paste(@paste_token, :powershell)

      assert paste ==
               "$env:DOITLIST_API_TOKEN = '#{@paste_token}'\n" <>
                 "setx DOITLIST_API_TOKEN '#{@paste_token}'\n" <>
                 "New-Item -ItemType Directory -Force (Split-Path $PROFILE) | Out-Null; " <>
                 "Add-Content -Path $PROFILE " <>
                 "-Value '$env:DOITLIST_API_TOKEN = ''#{@paste_token}''' -Encoding utf8\n" <>
                 "codex mcp add doitlist --url #{@paste_url} " <>
                 "--bearer-token-env-var DOITLIST_API_TOKEN"

      # 2.1.2.2's bar: live session via $env:, no bash-isms; 2.1.5's bar:
      # persistence that survives the shell host — the registry (setx) AND
      # the profile every new session sources — and both BEFORE the add.
      [env_line, setx_line, profile_line, add_line] = String.split(paste, "\n")
      assert env_line =~ "$env:DOITLIST_API_TOKEN"
      assert setx_line =~ "setx DOITLIST_API_TOKEN"
      assert profile_line =~ "Add-Content -Path $PROFILE"
      assert profile_line =~ "-Encoding utf8"
      # The profile line is created if missing, never truncated: a directory
      # New-Item, not a file one.
      assert profile_line =~ "New-Item -ItemType Directory -Force (Split-Path $PROFILE)"
      refute profile_line =~ "-ItemType File"
      assert add_line =~ "codex mcp add doitlist"
      refute paste =~ "export"
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

    test "client_pastes/2 keeps panel order; /1 defaults to :posix" do
      assert AgentConnect.client_pastes(@paste_token) ==
               AgentConnect.client_pastes(@paste_token, :posix)

      assert [
               {"claude-code", "Claude Code", _},
               {"codex", "Codex", _},
               {"hermes", "Hermes Agent", _}
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
