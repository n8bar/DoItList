defmodule DoIt.DocsGenTest do
  @moduledoc """
  The drift gate for `docs/reference/agent_surfaces.md` (m03.05 worklist 2):
  regenerating the committed file must reproduce it byte-for-byte. A hand
  edit inside a fence, or a code change that shifts a generated block
  without regenerating, fails this test with a readable diff.
  """
  use ExUnit.Case, async: true

  alias DoIt.DocsGen

  @moduletag :docs_gen

  test "the committed doc matches what the generator produces" do
    path = DocsGen.doc_path()
    committed = File.read!(path)
    regenerated = DocsGen.regenerate(committed)

    if regenerated != committed do
      flunk("""
      docs/reference/agent_surfaces.md is stale — run `mix doit.docs.gen` and commit the result.

      #{readable_diff(committed, regenerated)}
      """)
    end
  end

  test "the hand-written prose stays under its cap" do
    for relpath <- ["docs/reference/agent_surfaces.md", "docs/specs/agent_integration.md"] do
      words =
        File.cwd!()
        |> Path.join(relpath)
        |> File.read!()
        |> DoIt.DocsGen.prose_word_count()

      assert words < 1000,
             "#{relpath} is #{words} prose words; the cap is 1000 (m03.05 6.3, raised 2026-09-18)"
    end
  end

  test "refuses to write when a fence is missing, naming the file" do
    text = """
    <!-- generated: DoItWeb.Api.Operations -->
    <!-- /generated: DoItWeb.Api.Operations -->
    """

    assert_raise DocsGen.FenceError, ~r/agent_surfaces\.md.*missing fence/s, fn ->
      DocsGen.regenerate(text)
    end
  end

  test "refuses to write when a fence is unbalanced, naming the file" do
    text = """
    <!-- generated: DoItWeb.Api.Operations -->
    <!-- generated: DoItWeb.Api.Serializer -->
    <!-- /generated: DoItWeb.Api.Operations -->
    <!-- /generated: DoitMcp.Server -->
    <!-- /generated: scripts/doitlist.py -->
    """

    assert_raise DocsGen.FenceError, ~r/agent_surfaces\.md/, fn ->
      DocsGen.regenerate(text)
    end
  end

  test "refuses to write when a close marker has no matching open" do
    text = "<!-- /generated: DoItWeb.Api.Operations -->\n"

    assert_raise DocsGen.FenceError, ~r/no matching begin marker/, fn ->
      DocsGen.regenerate(text)
    end
  end

  defp readable_diff(a, b) do
    String.split(a, "\n")
    |> List.myers_difference(String.split(b, "\n"))
    |> Enum.flat_map(fn
      {:eq, _lines} -> []
      {:del, lines} -> Enum.map(lines, &"- #{&1}")
      {:ins, lines} -> Enum.map(lines, &"+ #{&1}")
    end)
    |> Enum.join("\n")
  end
end
