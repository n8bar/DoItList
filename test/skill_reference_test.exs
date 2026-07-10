defmodule DoIt.SkillReferenceTest do
  use ExUnit.Case, async: true

  # Drift guard: every doitlist tool/resource named in the companion skill's
  # Quick Reference must still exist as a registered MCP component. Catches a
  # tool rename/removal in mcp_server that leaves `skills/doitlist/SKILL.md`
  # pointing at a dead name — turning silent doc rot into a red test.
  #
  # "Known" names are derived from the `component(...)` registrations in
  # DoitMcp.Server, read as source text (mcp_server is a sibling mix project,
  # not a dep, so we can't reflect over its modules from here). "Referenced"
  # names are the first backtick token in each Quick Reference table row —
  # which, by the table's format, is always the tool/resource for that row.

  @server Path.expand("../mcp_server/lib/doit_mcp/server.ex", __DIR__)
  @skill Path.expand("../skills/doitlist/SKILL.md", __DIR__)

  test "the skill's Quick Reference names only real MCP tools/resources" do
    known = known_component_names()
    referenced = quick_reference_refs()

    assert MapSet.size(known) > 0,
           "parsed zero component() registrations from #{@server} — the parser is stale"

    assert MapSet.size(referenced) > 0,
           "parsed zero tool references from the skill's Quick Reference — the table format changed"

    unknown = MapSet.difference(referenced, known)

    assert MapSet.to_list(unknown) == [],
           "skills/doitlist/SKILL.md Quick Reference names MCP tools/resources that no longer " <>
             "exist: #{inspect(MapSet.to_list(unknown))}. Rename them here to match mcp_server, " <>
             "or drop the row."
  end

  # `component(DoitMcp.Tools.CreateInitiative)` -> "create_initiative"
  defp known_component_names do
    File.read!(@server)
    |> then(
      &Regex.scan(~r/component\(DoitMcp\.(?:Tools|Resources)\.(\w+)\)/, &1,
        capture: :all_but_first
      )
    )
    |> Enum.map(fn [mod] -> Macro.underscore(mod) end)
    |> MapSet.new()
  end

  # First backtick token in each Quick Reference table row's tool column.
  defp quick_reference_refs do
    @skill
    |> File.read!()
    |> quick_reference_section()
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "|"))
    |> Enum.flat_map(&tool_token/1)
    |> MapSet.new()
  end

  defp quick_reference_section(markdown) do
    case Regex.run(~r/^## Quick Reference\n(.*?)(?=\n## |\z)/ms, markdown,
           capture: :all_but_first
         ) do
      [section] -> section
      _ -> ""
    end
  end

  defp tool_token(row) do
    with cell when is_binary(cell) <- row |> String.split("|") |> Enum.at(2),
         [token] <- Regex.run(~r/`([a-z][a-z_]+)`/, cell, capture: :all_but_first) do
      [token]
    else
      _ -> []
    end
  end
end
