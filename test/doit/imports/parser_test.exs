defmodule DoIt.Imports.ParserTest do
  @moduledoc """
  Pure tests for the import parser (m03.04 items 2.1, 2.2 and 2.6.1). No DB —
  every supported source form, mapping rule and the title-overflow split is
  exercised one rule at a time, inline.

  Whole documents — the committed fixtures under
  `test/support/fixtures/imports/` and the repo's own `docs/PLAN.md` — are
  pinned in `fixtures_test.exs` (item 2.7).
  """
  use ExUnit.Case, async: true

  alias DoIt.Imports.Parser

  # --- helpers ---------------------------------------------------------------

  defp parse!(text) do
    {:ok, manifest} = Parser.parse(text)
    manifest
  end

  defp style(text), do: parse!(text).style

  # Titles as a nested {title, [children]} outline, so order and shape assert
  # in one literal.
  defp outline(items), do: Enum.map(items, &{&1.title, outline(&1.children)})

  defp titles(items), do: Enum.map(items, & &1.title)

  defp find(items, title) do
    Enum.find_value(items, fn item ->
      if item.title == title, do: item, else: find(item.children, title)
    end)
  end

  # --- 2.1.1 list markers ----------------------------------------------------

  describe "list items" do
    test "every bullet character makes a Task, in source order, with no numbering" do
      manifest =
        parse!("""
        - dash item
        * star item
        + plus item
        """)

      assert titles(manifest.items) == ["dash item", "star item", "plus item"]
      assert manifest.style == "none"
      assert manifest.title == nil
      assert manifest.counts == %{items: 3, done: 0, depth: 1, title_overflow: 0}
      assert Enum.all?(manifest.items, &(&1.description == nil and &1.done == false))
    end

    test "numbered markers are stripped from the title and set a numerical style" do
      manifest =
        parse!("""
        1. first
        2) second
        M3 third
        M04. fourth
        """)

      assert titles(manifest.items) == ["first", "second", "third", "fourth"]
      assert manifest.style == "numerical"
    end

    test "the rest of the title is kept verbatim" do
      manifest =
        parse!("""
        - **Ship it:** see `mix test` and https://doitlist.app/x
        """)

      assert titles(manifest.items) == ["**Ship it:** see `mix test` and https://doitlist.app/x"]
    end

    test "sentence openers that look like dotted paths stay prose" do
      manifest =
        parse!("""
        - a real item
        e.g. this is not an item
        i.e. neither is this
        """)

      assert titles(manifest.items) == ["a real item"]

      assert hd(manifest.items).description ==
               "e.g. this is not an item\ni.e. neither is this"
    end
  end

  # --- 2.1.4 checkboxes ------------------------------------------------------

  describe "checkboxes" do
    test "checked items map to done, unchecked and absent ones do not" do
      manifest =
        parse!("""
        - [x] lower checked
        - [X] upper checked
        - [ ] unchecked
        - no checkbox
        1. [x] numbered and checked
        """)

      assert Enum.map(manifest.items, &{&1.title, &1.done}) == [
               {"lower checked", true},
               {"upper checked", true},
               {"unchecked", false},
               {"no checkbox", false},
               {"numbered and checked", true}
             ]

      assert manifest.counts == %{items: 5, done: 3, depth: 1, title_overflow: 0}
    end

    test "items record whether the line carried a checkbox at all" do
      manifest =
        parse!("""
        # Plan
        ## Section
        - [ ] boxed
        - plain
        """)

      assert Enum.map(manifest.items, &{&1.title, &1.checkbox}) == [{"Section", false}]
      [%{children: children}] = manifest.items
      assert Enum.map(children, &{&1.title, &1.checkbox}) == [{"boxed", true}, {"plain", false}]
    end
  end

  # --- 2.1.2 nesting ---------------------------------------------------------

  describe "nesting from indentation" do
    test "tabs, two spaces and four spaces all nest the same way" do
      expected = [{"root", [{"child", [{"grandchild", []}]}, {"sibling", []}]}]

      tabs = "- root\n\t- child\n\t\t- grandchild\n\t- sibling\n"
      two = "- root\n  - child\n    - grandchild\n  - sibling\n"
      four = "- root\n    - child\n        - grandchild\n    - sibling\n"

      for text <- [tabs, two, four] do
        manifest = parse!(text)
        assert outline(manifest.items) == expected
        assert manifest.counts == %{items: 4, done: 0, depth: 3, title_overflow: 0}
      end
    end

    test "a shallower item pops back out to its own level" do
      manifest =
        parse!("""
        - one
          - one-a
            - one-a-i
          - one-b
        - two
        """)

      assert outline(manifest.items) == [
               {"one", [{"one-a", [{"one-a-i", []}]}, {"one-b", []}]},
               {"two", []}
             ]
    end

    test "source order is preserved through a three-level tree with mixed markers" do
      manifest =
        parse!("""
        1. alpha
          - alpha one
            * alpha one deep
          + alpha two
        2. beta
          - beta one
        3. gamma
        """)

      assert outline(manifest.items) == [
               {"alpha", [{"alpha one", [{"alpha one deep", []}]}, {"alpha two", []}]},
               {"beta", [{"beta one", []}]},
               {"gamma", []}
             ]

      assert manifest.counts == %{items: 7, done: 0, depth: 3, title_overflow: 0}
      assert manifest.style == "numerical"
    end
  end

  # --- 2.1.1 / 2.1.6 headings ------------------------------------------------

  describe "headings" do
    test "a lone opening heading becomes the title, never a wrapper Task" do
      manifest =
        parse!("""
        # Launch plan

        - first
        - second
        """)

      assert manifest.title == "Launch plan"
      assert titles(manifest.items) == ["first", "second"]
      assert manifest.counts == %{items: 2, done: 0, depth: 1, title_overflow: 0}
      refute Map.has_key?(manifest, :title_description)
    end

    test "two headings at the same level are both branches and there is no title" do
      manifest =
        parse!("""
        # Backend
        - api
        # Frontend
        - ui
        """)

      assert manifest.title == nil

      assert outline(manifest.items) == [
               {"Backend", [{"api", []}]},
               {"Frontend", [{"ui", []}]}
             ]
    end

    test "heading level sets nesting and lists hang off the open heading" do
      manifest =
        parse!("""
        # Plan
        ## Phase one
        - a
          - a1
        ### Deep
        - d
        ## Phase two
        - b
        """)

      assert manifest.title == "Plan"

      assert outline(manifest.items) == [
               {"Phase one", [{"a", [{"a1", []}]}, {"Deep", [{"d", []}]}]},
               {"Phase two", [{"b", []}]}
             ]

      assert manifest.counts == %{items: 7, done: 0, depth: 3, title_overflow: 0}
    end

    test "a heading-only outline nests by heading level alone" do
      manifest =
        parse!("""
        ## Alpha
        ### Alpha one
        #### Alpha one deep
        ## Beta
        """)

      assert manifest.title == nil

      assert outline(manifest.items) == [
               {"Alpha", [{"Alpha one", [{"Alpha one deep", []}]}]},
               {"Beta", []}
             ]

      assert manifest.counts == %{items: 4, done: 0, depth: 3, title_overflow: 0}
    end

    test "an opening heading deeper than the shallowest one is not the title" do
      manifest =
        parse!("""
        ## Intro
        - a
        # Body
        - b
        """)

      assert manifest.title == nil
      assert titles(manifest.items) == ["Intro", "Body"]
    end
  end

  # --- 2.1.5 prose -----------------------------------------------------------

  describe "prose as description" do
    test "prose attaches to the nearest preceding item, paragraphs kept apart" do
      manifest =
        parse!("""
        - first
          why it matters

          a second paragraph
        - second
          only one note
        """)

      assert find(manifest.items, "first").description ==
               "why it matters\n\na second paragraph"

      assert find(manifest.items, "second").description == "only one note"
    end

    test "prose that merely repeats the title is dropped" do
      manifest =
        parse!("""
        # Doc
        ## Section
        Section
        - [ ] Ship the parser
          Ship the parser
          ship the PARSER
          real detail
        """)

      assert find(manifest.items, "Section").description == nil
      assert find(manifest.items, "Ship the parser").description == "real detail"
    end

    test "preamble prose lands on the target, not on a Task" do
      with_title =
        parse!("""
        # Launch plan
        Context for the whole import.

        - first
        """)

      assert with_title.title == "Launch plan"
      assert with_title.title_description == "Context for the whole import."
      assert titles(with_title.items) == ["first"]

      without_title =
        parse!("""
        A loose opening paragraph.

        - first
        """)

      assert without_title.title == nil
      assert without_title.title_description == "A loose opening paragraph."
      assert titles(without_title.items) == ["first"]
    end

    test "table rows and fenced code become description text, never Tasks" do
      manifest =
        parse!("""
        - Reference
          | Key | Value |
          |---|---|
          | a | 1 |

        ```elixir
        1. not a task
        - not a task either
        ```
        - Next
        """)

      description = find(manifest.items, "Reference").description

      assert description ==
               "| Key | Value |\n|---|---|\n| a | 1 |\n\n```elixir\n1. not a task\n- not a task either\n```"

      assert titles(manifest.items) == ["Reference", "Next"]
      assert manifest.counts == %{items: 2, done: 0, depth: 1, title_overflow: 0}
    end

    test "blockquotes are description text" do
      manifest =
        parse!("""
        - Quote holder
          > borrowed words
        """)

      assert find(manifest.items, "Quote holder").description == "> borrowed words"
    end
  end

  # --- 2.6.1 title overflow ---------------------------------------------------

  describe "titles past the 200-character cap" do
    test "split at the last whitespace inside the cap, remainder leading the description" do
      # 42 five-letter words: the 200th character lands mid-word, so the cut
      # falls back to the space before it.
      long = Enum.map_join(1..42, " ", fn _ -> "chunk" end)
      assert String.length(long) == 251

      [item] = parse!("- #{long}\n").items

      assert String.length(item.title) <= Parser.max_title()
      # Near the cap, so the cut took the LAST space inside it, not an early one.
      assert String.length(item.title) > Parser.max_title() - 10
      # Nothing lost: title and remainder rejoin into the source line.
      assert item.title <> " " <> item.description == long
    end

    test "with no whitespace inside the cap, cut hard at the cap" do
      long = String.duplicate("x", 250)

      [item] = parse!("- #{long}\n").items

      assert item.title == String.duplicate("x", 200)
      assert item.description == String.duplicate("x", 50)
    end

    test "the remainder leads prose the item already had" do
      long = String.duplicate("x", 250)

      [item] =
        parse!("""
        - #{long}
          Some detail about it.
        """).items

      assert item.description == String.duplicate("x", 50) <> "\n\nSome detail about it."
    end

    test "counts.title_overflow counts the split items only" do
      long = String.duplicate("x", 250)

      manifest =
        parse!("""
        - #{long}
        - short one
          - #{long}
        """)

      assert manifest.counts == %{items: 3, done: 0, depth: 2, title_overflow: 2}
      assert Enum.all?(manifest.items, &(String.length(&1.title) <= Parser.max_title()))
    end

    test "the manifest title is never split — it is a document heading, not a Task" do
      long = String.duplicate("x", 250)
      manifest = parse!("# #{long}\n\n- a task\n")

      assert manifest.title == long
      assert manifest.counts.title_overflow == 0
    end
  end

  # --- 2.2 style detection ---------------------------------------------------

  describe "index style detection" do
    test "plain bullets are none" do
      assert style("- a\n- b\n") == "none"
      assert style("# Only headings\n## Branch\n### Leaf\n") == "none"
    end

    test "decimal, paren and letter-prefixed numbering are numerical" do
      assert style("1. a\n2. b\n") == "numerical"
      assert style("1) a\n2) b\n") == "numerical"
      assert style("M1 a\nM2 b\n") == "numerical"
      assert style("M01. a\nM02. b\n") == "numerical"
      assert style("1.1 a\n1.2 b\n") == "numerical"
    end

    test "dotted paths mixing segment kinds are outline" do
      assert style("I.A.2 a\nI.A.3 b\n") == "outline"
      assert style("1.a.i a\n1.a.ii b\n") == "outline"
    end

    test "roman numerals are roman" do
      assert style("I. a\nII. b\nIII. c\n") == "roman"
      assert style("i) a\nii) b\n") == "roman"
      assert style("IV. a\n") == "roman"
    end

    test "progressing letters are alphabetical" do
      assert style("A. a\nB. b\nC. c\n") == "alphabetical"
      assert style("a) one\nb) two\n") == "alphabetical"
      assert style("B. lone non-roman letter\n") == "alphabetical"
      assert style("I. a\nJ. b\nK. c\n") == "alphabetical"
    end

    test "ambiguous or mixed numbering falls back to numerical" do
      assert style("I. a lone roman-or-letter marker\n") == "numerical"
      assert style("1. a\nA. b\n") == "numerical"
      assert style("I. a\nV. b\nX. c\n") == "numerical"
    end

    test "only the shallowest marked level has to agree" do
      manifest =
        parse!("""
        I. first
          1. nested numeric
          2. also numeric
        II. second
        """)

      assert manifest.style == "roman"
    end

    test "numbering below plain bullets still sets the style" do
      assert style("- a\n  1. one\n  2. two\n") == "numerical"
    end
  end

  # --- letter+digit markers require a sequence --------------------------------

  describe "letter+digit markers require a sequence" do
    test "a heading that only looks like a marker keeps its full title" do
      manifest =
        parse!("""
        # Q3 Plan
        - a
        - b
        """)

      assert manifest.title == "Q3 Plan"
      assert manifest.style == "none"
    end

    test "different letters are not a sequence, so neither is stripped" do
      manifest =
        parse!("""
        - B2 pencils
        - C4 paper
        """)

      assert titles(manifest.items) == ["B2 pencils", "C4 paper"]
    end

    test "the same letter recurring with different digit runs is numbering" do
      manifest =
        parse!("""
        M1 a
        M2 b
        """)

      assert titles(manifest.items) == ["a", "b"]
      assert manifest.style == "numerical"
    end

    test "the same letter and digit run twice is not a sequence, so the lines are prose" do
      manifest =
        parse!("""
        - a
        Q3 targets are aggressive.
        Q3 goals follow.
        - b
        """)

      assert titles(manifest.items) == ["a", "b"]
      assert hd(manifest.items).description == "Q3 targets are aggressive.\nQ3 goals follow."
      assert Parser.parse("Q3 Plan\nQ3 goals\n") == {:error, :empty}
    end
  end

  # --- 2.1 empty input -------------------------------------------------------

  describe "empty input" do
    test "blank, whitespace-only and item-free text are :empty" do
      assert Parser.parse("") == {:error, :empty}
      assert Parser.parse("   \n\n\t\n") == {:error, :empty}
      assert Parser.parse("just a paragraph, no items at all\n") == {:error, :empty}
      assert Parser.parse("# Title only\n\nwith prose\n") == {:error, :empty}
      assert Parser.parse(nil) == {:error, :empty}
    end
  end

  # --- operations/2 ----------------------------------------------------------

  describe "operations/2" do
    setup do
      manifest =
        parse!("""
        1. alpha
          - alpha one
            - [x] deep
        2. beta
          detail for beta
        """)

      %{manifest: manifest}
    end

    test "a new Initiative leads, carries the detected style, and roots link to it", %{
      manifest: manifest
    } do
      ops = Parser.operations(manifest, {:new_initiative, "Imported plan"})

      assert [initiative | tasks] = ops

      assert initiative == %{
               "op" => "add",
               "type" => "initiative",
               "lid" => "i1",
               "data" => %{"name" => "Imported plan", "index_style" => "numerical"}
             }

      assert Enum.map(tasks, & &1["lid"]) == ~w(t1 t2 t3 t4)
      assert Enum.map(tasks, & &1["data"]["title"]) == ["alpha", "alpha one", "deep", "beta"]
      assert Enum.all?(tasks, &(&1["op"] == "add" and &1["type"] == "task"))

      assert Enum.map(tasks, &{&1["data"]["initiative_lid"], &1["data"]["parent_lid"]}) == [
               {"i1", nil},
               {nil, "t1"},
               {nil, "t2"},
               {"i1", nil}
             ]

      assert Enum.find(tasks, &(&1["lid"] == "t3"))["data"]["done"] == true
      refute Map.has_key?(Enum.find(tasks, &(&1["lid"] == "t1"))["data"], "done")

      assert Enum.find(tasks, &(&1["lid"] == "t4"))["data"]["description"] == "detail for beta"
      refute Map.has_key?(Enum.find(tasks, &(&1["lid"] == "t1"))["data"], "description")

      refute Enum.any?(ops, &Map.has_key?(&1["data"], "position"))
      assert Parser.count_ops(ops) == 5
      assert Parser.count_ops(manifest) == 4
    end

    test "an existing Initiative target puts roots top-level under it", %{manifest: manifest} do
      ops = Parser.operations(manifest, {:initiative, 42})

      assert Enum.map(ops, & &1["lid"]) == ~w(t1 t2 t3 t4)
      assert Enum.all?(ops, &(&1["type"] == "task"))

      assert Enum.map(ops, &{&1["data"]["initiative_id"], &1["data"]["parent_lid"]}) == [
               {42, nil},
               {nil, "t1"},
               {nil, "t2"},
               {42, nil}
             ]
    end

    test "an existing Task target parents the roots to it", %{manifest: manifest} do
      ops = Parser.operations(manifest, {:task, 7})

      assert Enum.map(ops, &{&1["data"]["parent_id"], &1["data"]["parent_lid"]}) == [
               {7, nil},
               {nil, "t1"},
               {nil, "t2"},
               {7, nil}
             ]
    end

    test "every parent lid is emitted before the children that reference it", %{
      manifest: manifest
    } do
      ops = Parser.operations(manifest, {:new_initiative, "Imported plan"})

      Enum.reduce(ops, MapSet.new(), fn op, seen ->
        parent = op["data"]["parent_lid"]
        if parent, do: assert(MapSet.member?(seen, parent))
        MapSet.put(seen, op["lid"])
      end)

      assert length(Enum.uniq(Enum.map(ops, & &1["lid"]))) == length(ops)
    end
  end

  # --- 6.10.1 section slice ---------------------------------------------------

  describe "section/2" do
    @doc_with_sections """
    # Milestone 3

    Front matter that must not import with a section.

    ## Arc 3

    - Old work

    ## Arc 4

    Intro to the arc.

    1. First item
       1. Nested item
    2. Second item

    ### Worklist notes

    - A note under a deeper heading

    ## Arc 5

    - Later work
    """

    test "the slice starts after the heading and stops at the next same-level heading" do
      {:ok, slice, _offset} = Parser.section(@doc_with_sections, "Arc 4")

      assert slice == """

             Intro to the arc.

             1. First item
                1. Nested item
             2. Second item

             ### Worklist notes

             - A note under a deeper heading
             """

      manifest = parse!(slice)
      # The heading itself is gone, so the section's first child is the first root.
      assert manifest.title == nil

      assert outline(manifest.items) == [
               {"First item", [{"Nested item", []}]},
               {"Second item", []},
               {"Worklist notes", [{"A note under a deeper heading", []}]}
             ]

      assert manifest.title_description == "Intro to the arc."
    end

    test "a higher-level heading also ends the slice" do
      {:ok, slice, _offset} = Parser.section("## A\n- a1\n# Top\n- t1\n", "A")
      assert slice == "- a1"
    end

    test "the last section runs to the end of the document" do
      {:ok, slice, _offset} = Parser.section(@doc_with_sections, "Arc 5")
      assert String.trim(slice) == "- Later work"
    end

    test "leading #s, surrounding space, and a checkbox on either side are ignored" do
      text = "## [x] Ship it\n- s1\n## Next\n- n1\n"

      for heading <- ["Ship it", "## Ship it", "  Ship it  ", "[ ] Ship it", "##  [x] Ship it"] do
        assert {:ok, "- s1", _} = Parser.section(text, heading), heading
      end
    end

    test "matching is exact otherwise" do
      text = "## Ship it\n- s1\n"
      assert {:error, :not_found} = Parser.section(text, "ship it")
      assert {:error, :not_found} = Parser.section(text, "Ship")
      assert {:error, :not_found} = Parser.section(text, "Nowhere")
    end

    test "a heading that appears more than once is ambiguous" do
      text = "## Notes\n- a\n## Other\n- b\n### Notes\n- c\n"
      assert {:error, {:ambiguous, 2}} = Parser.section(text, "Notes")
    end

    test "headings inside fenced code are not candidates or boundaries" do
      text = "## Real\n- r1\n```\n## Fake\n- not an item\n```\n- r2\n## Next\n- n1\n"
      assert {:error, :not_found} = Parser.section(text, "Fake")
      {:ok, slice, _offset} = Parser.section(text, "Real")
      assert slice == "- r1\n```\n## Fake\n- not an item\n```\n- r2"
    end

    test "a heading with nothing under it slices to nothing, which parse refuses" do
      {:ok, slice, _offset} = Parser.section("## Empty\n## Next\n- n1\n", "Empty")
      assert slice == ""
      assert Parser.parse(slice) == {:error, :empty}
    end

    test "the offset is how many whole-document lines precede the slice" do
      # Line 9 of @doc_with_sections is "## Arc 4", so its slice starts at
      # line 10 and nine lines precede it.
      {:ok, slice, offset} = Parser.section(@doc_with_sections, "Arc 4")
      assert offset == 9

      lines = String.split(@doc_with_sections, "\n")
      first = parse!(slice).items |> hd()

      assert first.title == "First item"
      assert Enum.at(lines, first.line + offset - 1) == "1. First item"
    end

    test "the first section's slice starts right after its heading" do
      {:ok, _slice, offset} = Parser.section("## A\n- a1\n", "A")
      assert offset == 1
    end

    test "an annotated heading still names its section" do
      # A mirror written back by `--write-ids` carries the branch's own id on
      # the heading line; naming the section must not have to know that.
      text = "## Arc 4 %<110>\n- a1\n## Arc 5\n- b1\n"
      assert {:ok, "- a1", 1} = Parser.section(text, "Arc 4")
      assert {:ok, "- a1", 1} = Parser.section(text, "## Arc 4 %<110>")
    end
  end

  # --- 6.12.2 source lines ----------------------------------------------------

  describe "source lines" do
    test "every item records the 1-based line that produced it" do
      manifest =
        parse!("""
        # Plan

        Preamble prose.

        ## Arc 4

        1. First item
           prose under the first item

           1. Nested item
        2. [x] Second item
        """)

      assert [arc] = manifest.items
      assert {arc.title, arc.line} == {"Arc 4", 5}

      assert Enum.map(arc.children, &{&1.title, &1.line}) == [
               {"First item", 7},
               {"Second item", 11}
             ]

      assert [nested] = hd(arc.children).children
      assert {nested.title, nested.line} == {"Nested item", 10}
    end

    test "a document with no title heading counts from its first line" do
      manifest = parse!("- alpha\n- beta\n")
      assert Enum.map(manifest.items, & &1.line) == [1, 2]
    end

    test "a fenced code block's lines are counted, not skipped" do
      manifest =
        parse!("""
        - alpha

        ```
        - not an item
        ```

        - beta
        """)

      assert Enum.map(manifest.items, &{&1.title, &1.line}) == [{"alpha", 1}, {"beta", 7}]
    end

    test "an overflowing title keeps the line of the one source line it came from" do
      long = String.duplicate("word ", 60)
      manifest = parse!("- first\n- #{long}\n")
      assert Enum.map(manifest.items, & &1.line) == [1, 2]
      assert manifest.counts.title_overflow == 1
    end
  end

  # --- 6.12.2 operations carry their lines ------------------------------------

  describe "operations_and_lines/2" do
    test "pairs every task lid with the source line it came from, in emission order" do
      manifest =
        parse!("""
        1. alpha
          - alpha one
        2. beta
        """)

      {ops, lines} = Parser.operations_and_lines(manifest, {:new_initiative, "Imported"})

      assert lines == [{"t1", 1}, {"t2", 2}, {"t3", 3}]
      # The Initiative op is no item's line, so it gets no pair.
      assert length(ops) == length(lines) + 1
      assert Parser.operations(manifest, {:new_initiative, "Imported"}) == ops
    end

    test "an existing target pairs the same lids" do
      manifest = parse!("- alpha\n- beta\n")
      assert {_ops, [{"t1", 1}, {"t2", 2}]} = Parser.operations_and_lines(manifest, {:task, 7})
    end
  end

  # --- 6.12.5 the id annotation is not title text -----------------------------

  describe "trailing id annotations" do
    test "a trailing %<id> is stripped from a checkbox, bullet, numbered or heading title" do
      manifest =
        parse!("""
        ## Arc 4 %<110>

        - [x] Ship it %<111>
        - Tell everyone %<112>
        1. Numbered %<113>
        """)

      # The lone top heading is the manifest title, annotation and all stripped.
      assert manifest.title == "Arc 4"

      assert Enum.map(manifest.items, & &1.title) == ["Ship it", "Tell everyone", "Numbered"]
    end

    test "an annotated document parses exactly as its unannotated self" do
      plain = "# Plan\n\n- [x] Ship it\n  - Draft it\n- Tell everyone\n"
      annotated = "# Plan %<100>\n\n- [x] Ship it %<111>\n  - Draft it %<112>\n- Tell everyone %<113>\n"

      assert parse!(annotated) == parse!(plain)
    end

    test "only a trailing annotation goes" do
      manifest =
        parse!("""
        - See %<272> Ship the parser for the shape
        - %<9>
        - Trailing only %<9>
        """)

      assert titles(manifest.items) == [
               "See %<272> Ship the parser for the shape",
               "%<9>",
               "Trailing only"
             ]
    end

    test "an annotation does not follow the title into a description" do
      manifest = parse!("- Ship it %<111>\n  detail about %<111> the work\n")
      assert [item] = manifest.items
      assert item.title == "Ship it"
      assert item.description == "detail about %<111> the work"
    end
  end
end
