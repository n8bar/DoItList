defmodule DoItWeb.AgentConnectTest do
  @moduledoc """
  m03.04 item 24.1: `DoItWeb.AgentConnect.mcp_url/0` — both lanes: the
  `:mcp_public_url` override, and composition from the endpoint's public host
  plus `:mcp_public_port` when unset. `async: false`: mutates global app env.
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
end
