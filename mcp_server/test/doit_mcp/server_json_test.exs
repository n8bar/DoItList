defmodule DoitMcp.ServerJsonTest do
  use ExUnit.Case, async: true

  # Registry-descriptor pinning (m03.04 2.1.1.5). server.json is authored
  # here and publishes at M05; these assertions keep its structure honest as
  # the adapter evolves — they do not reimplement registry validation (the
  # descriptor was validated against the 2025-12-11 server.schema.json when
  # authored; the registry re-validates at publish).

  @server_json Path.expand("../../server.json", __DIR__)

  setup_all do
    %{descriptor: JSON.decode!(File.read!(@server_json))}
  end

  test "carries the registry identity", %{descriptor: descriptor} do
    assert %{"name" => "app.doitlist/mcp", "description" => _, "version" => _} = descriptor
  end

  test "exactly one remote, of type streamable-http", %{descriptor: descriptor} do
    assert [%{"type" => "streamable-http"}] = descriptor["remotes"]
  end

  test "URL template ends with one slash and declares every variable it references",
       %{descriptor: descriptor} do
    [remote] = descriptor["remotes"]
    url = remote["url"]

    # Same shape DoItWeb.AgentConnect.mcp_url/0 emits: base URL, exactly one
    # trailing slash.
    assert String.ends_with?(url, "/")
    refute String.ends_with?(url, "//")

    referenced = for [_, var] <- Regex.scan(~r/\{([^}]+)\}/, url), do: var
    declared = Map.keys(remote["variables"] || %{})

    assert "host" in referenced
    assert referenced -- declared == []
  end

  test "the Authorization header is a required secret", %{descriptor: descriptor} do
    [remote] = descriptor["remotes"]
    auth = Enum.find(remote["headers"], &(&1["name"] == "Authorization"))

    assert %{"isRequired" => true, "isSecret" => true} = auth
  end

  test "version matches the adapter's mix.exs", %{descriptor: descriptor} do
    assert descriptor["version"] == to_string(Mix.Project.config()[:version])
  end
end
