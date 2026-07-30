defmodule DoItWeb.AgentConnectTest do
  @moduledoc """
  m03.04 item 24.1: `DoItWeb.AgentConnect.mcp_url/0` — both lanes: the
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
               "claude mcp add --transport http doit-list #{@paste_url} " <>
                 ~s(--header "Authorization: Bearer #{@paste_token}")
    end

    test "codex_paste/1 rides export, add, and profile append in one paste" do
      paste = AgentConnect.codex_paste(@paste_token)

      assert paste ==
               "export DOITLIST_API_TOKEN='#{@paste_token}'\n" <>
                 "codex mcp add doit-list --url #{@paste_url} " <>
                 "--bearer-token-env-var DOITLIST_API_TOKEN\n" <>
                 ~s(echo "export DOITLIST_API_TOKEN='#{@paste_token}'" >> ~/.bashrc) <>
                 "   # or your shell's profile"

      # 24.3's bar spelled out: the credential export, the add, and the
      # profile append all in the same paste.
      assert paste =~ "export DOITLIST_API_TOKEN='#{@paste_token}'"
      assert paste =~ "codex mcp add doit-list"
      assert paste =~ ">> ~/.bashrc"
    end

    test "hermes_paste/1 appends the bare token under MCP_DOIT_LIST_API_KEY" do
      paste = AgentConnect.hermes_paste(@paste_token)

      assert paste ==
               "hermes mcp add doit-list --url #{@paste_url} --auth header\n" <>
                 ~s(echo "MCP_DOIT_LIST_API_KEY=#{@paste_token}" >> ~/.hermes/.env)

      [_add_line, env_line] = String.split(paste, "\n")
      assert env_line =~ "MCP_DOIT_LIST_API_KEY=#{@paste_token}"
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
end
