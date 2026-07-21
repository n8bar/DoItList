defmodule DoItWeb.Api.SerializerUrlTest do
  @moduledoc """
  `url` on initiative payloads (m03.04 item 2.14) — the operator-facing handle.

  Pure serializer unit tests: the URL is composed from the endpoint's public
  URL config (scheme + host, never hard-coded), and it is present on BOTH
  initiative reads — the list summary and the tree header.
  """
  use ExUnit.Case, async: true

  alias DoIt.Initiatives.Initiative
  alias DoItWeb.Api.Serializer

  defp initiative do
    %Initiative{
      id: 57,
      name: "Q3 Launch",
      subtitle: "ship it",
      progress_calc: "leaf_average",
      index_style: "none",
      ai_knobs: nil,
      root_task_id: 100
    }
  end

  test "the url is composed from the endpoint's public URL config" do
    %{url: url} = Serializer.initiative_summary(initiative(), "owner", 42)

    endpoint = URI.parse(DoItWeb.Endpoint.url())
    composed = URI.parse(url)

    assert composed.scheme == endpoint.scheme
    assert composed.host == endpoint.host
    assert composed.port == endpoint.port
    assert composed.path == "/initiatives/57"
  end

  test "the list summary and the tree header carry the same url" do
    ini = initiative()
    expected = DoItWeb.Endpoint.url() <> "/initiatives/#{ini.id}"

    summary = Serializer.initiative_summary(ini, "owner", 42)
    tree = Serializer.initiative_tree(ini, [], "owner", "ship it", 42, %{}, %{}, [])

    assert summary.url == expected
    assert tree.url == expected
  end
end
