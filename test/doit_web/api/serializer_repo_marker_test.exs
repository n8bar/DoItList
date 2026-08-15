defmodule DoItWeb.Api.SerializerRepoMarkerTest do
  @moduledoc """
  `repo_marker` on initiative payloads (m03.04 2.1.4.1) — the two-line
  agent-instruction-file snippet.

  Pure serializer unit tests: both initiative reads — the list summary and
  the tree header — carry `DoItWeb.AgentConnect.repo_marker/1`'s exact
  composition, so the panel and the API can never fork wording (the exact
  wording itself is pinned in `DoItWeb.AgentConnectTest`).
  """
  use ExUnit.Case, async: true

  alias DoIt.Initiatives.Initiative
  alias DoItWeb.AgentConnect
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

  test "the list summary and the tree header carry AgentConnect's composed marker" do
    ini = initiative()

    summary = Serializer.initiative_summary(ini, "owner", 42)
    tree = Serializer.initiative_tree(ini, [], "owner", "ship it", 42, %{}, %{}, [])

    assert summary.repo_marker == AgentConnect.repo_marker(ini)
    assert tree.repo_marker == AgentConnect.repo_marker(ini)
  end

  test "the marker leads with the '## Do It List' heading and carries the Initiative's URL" do
    %{repo_marker: marker} = Serializer.initiative_summary(initiative(), "owner", 42)

    assert String.starts_with?(marker, "## Do It List\n")
    assert marker =~ DoItWeb.Endpoint.url() <> "/initiatives/57"
  end
end
