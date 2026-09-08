defmodule DoIt.SkillReferenceTest do
  use ExUnit.Case, async: true

  # Drift guard: every MCP tool/resource and every CLI verb the companion skill
  # names must still exist. Catches a rename or removal in mcp_server or
  # doitlist.py that leaves `skills/doitlist/SKILL.md` pointing at a dead name.
  #
  # Known MCP names are derived from the `component(...)` registrations in
  # DoitMcp.Server, read as source text (mcp_server is a sibling mix project,
  # not a dep). Known CLI verbs are the subparser names in doitlist.py.
  # Referenced names are read from the whole skill, not one section, so the
  # guard survives restructuring: a backticked snake_case token with an
  # underscore is an MCP name; a backticked token that opens a CLI command
  # line (`doitlist.py <verb>` or a bare verb followed by arguments) is a verb.

  @server Path.expand("../mcp_server/lib/doit_mcp/server.ex", __DIR__)
  @cli Path.expand("../skills/doitlist/scripts/doitlist.py", __DIR__)
  @skill Path.expand("../skills/doitlist/SKILL.md", __DIR__)

  # Backticked interpreter names in the Platforms section are not verbs.
  @interpreters ~w(py python python3)

  test "the skill names only real MCP tools/resources" do
    known = known_component_names()
    referenced = mcp_refs()

    assert MapSet.size(known) > 0,
           "parsed zero component() registrations from #{@server} — the parser is stale"

    assert MapSet.size(referenced) > 0,
           "parsed zero MCP names from the skill — the naming convention changed"

    unknown = MapSet.difference(referenced, known)

    assert MapSet.to_list(unknown) == [],
           "skills/doitlist/SKILL.md names MCP tools/resources that no longer exist: " <>
             "#{inspect(MapSet.to_list(unknown))}. Rename them to match mcp_server or drop them."
  end

  test "the skill names only real CLI verbs" do
    known = known_cli_verbs()
    referenced = cli_verb_refs()

    assert MapSet.size(known) > 0,
           "parsed zero subparsers from #{@cli} — the parser is stale"

    assert MapSet.size(referenced) > 0,
           "parsed zero CLI verbs from the skill — the command-line convention changed"

    unknown = MapSet.difference(referenced, known)

    assert MapSet.to_list(unknown) == [],
           "skills/doitlist/SKILL.md names CLI verbs that doitlist.py does not define: " <>
             "#{inspect(MapSet.to_list(unknown))}."
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

  # `sub.add_parser("tree", ...)` -> "tree"
  defp known_cli_verbs do
    File.read!(@cli)
    |> then(&Regex.scan(~r/add_parser\(\s*"([a-z]+)"/, &1, capture: :all_but_first))
    |> Enum.map(fn [verb] -> verb end)
    |> MapSet.new()
  end

  # Every backticked snake_case token with an underscore: `import_text`.
  defp mcp_refs do
    File.read!(@skill)
    |> then(&Regex.scan(~r/`([a-z]+(?:_[a-z]+)+)`/, &1, capture: :all_but_first))
    |> Enum.map(fn [name] -> name end)
    |> MapSet.new()
  end

  # A backticked command line: `doitlist.py tree ...`, `tree <initiative> ...`,
  # or a bare verb in a comma list like `add`, `done`, `move` — any backticked
  # token that is a single lowercase word, plus the word after `doitlist.py`.
  defp cli_verb_refs do
    skill = File.read!(@skill)

    after_script =
      Regex.scan(~r/`(?:python3 |py -3 |python )?(?:[\w\/\\.]*doitlist\.py) ([a-z]+)/, skill,
        capture: :all_but_first
      )

    bare =
      Regex.scan(~r/`([a-z]+)(?: <[^`]*)?`/, skill, capture: :all_but_first)

    (after_script ++ bare)
    |> Enum.map(fn [verb] -> verb end)
    |> Enum.reject(&(&1 in @interpreters))
    |> MapSet.new()
  end
end
