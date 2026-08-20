defmodule DoitMcp.BatchShapeTest do
  use ExUnit.Case, async: true

  alias DoitMcp.BatchShape

  defp add(title, desc \\ nil) do
    data = %{"initiative_lid" => "i", "title" => title}
    data = if desc, do: Map.put(data, "description", desc), else: data
    %{"op" => "add", "type" => "task", "lid" => title, "data" => data}
  end

  defp mirror_batch(n) do
    for i <- 1..n, do: add("docs/file#{i}.md", String.duplicate("x", 2_100) <> "#{i}")
  end

  describe "classify/1 refusals" do
    test "a file-mirror batch refuses with counts and the override path" do
      assert {:refuse, message} = BatchShape.classify(mirror_batch(12))
      assert message =~ "12 of 12 new task titles look like file paths/names"
      assert message =~ "whole-file sized"
      assert message =~ "file-mirror import"
      assert message =~ "`operator_confirmed: true` plus `readback`"
    end

    test "mirror needs both signals — path titles alone pass" do
      ops = for i <- 1..12, do: add("docs/file#{i}.md")
      assert BatchShape.classify(ops) == :pass
    end

    test "a mirror-shaped batch under the size floor passes" do
      assert BatchShape.classify(mirror_batch(9)) == :pass
    end

    test "checklists at scale refuse as the dropped task layer" do
      desc = "- [ ] one\n- [ ] two\n- [x] three\n"
      ops = for i <- 1..10, do: add("Real item #{i}", desc <> "#{i}")

      assert {:refuse, message} = BatchShape.classify(ops)
      assert message =~ "30 markdown-checkbox lines"
      assert message =~ "task layer this import dropped"
    end

    test "boilerplate at scale refuses" do
      ops = for i <- 1..10, do: add("Item #{i}", "Completable item from the ordered checklist.")

      assert {:refuse, message} = BatchShape.classify(ops)
      assert message =~ "stamped on 10 tasks"
      assert message =~ "boilerplate"
    end

    test "short repeated descriptions are not boilerplate" do
      ops = for i <- 1..12, do: add("Item #{i}", "TBD")
      assert BatchShape.classify(ops) == :pass
    end
  end

  describe "classify/1 sub-scale checklist refusal (m03.04 2.8.4.2)" do
    test "one checklist-bearing description refuses with the subtasks-or-ask recovery" do
      ops = [add("Setup", "Steps:\n- [ ] install\n- [ ] configure"), add("Cleanup")]

      assert {:refuse, message} = BatchShape.classify(ops)
      assert message =~ "2 markdown-checkbox lines"
      assert message =~ "Import them as subtasks instead"
      assert message =~ "ask the operator in chat"
      assert message =~ "`operator_confirmed: true`"
    end

    test "a single stray checkbox line is noise — passes" do
      assert BatchShape.classify([add("Setup", "- [x] done already")]) == :pass
    end

    test "numbered checkboxes refuse like bullets — `N.` and `N)` forms both count (m03.04 2.9.2)" do
      desc = "1. [x] Define the release package contract.\n2) [ ] Wire the installer."

      assert {:refuse, message} = BatchShape.classify([add("Worklist", desc)])
      assert message =~ "2 markdown-checkbox lines"
      assert message =~ "subtasks"
    end

    test "a numbered list without checkbox boxes passes" do
      desc = "1. Define the contract\n2. Wire the installer\n3. Ship it"
      assert BatchShape.classify([add("Worklist", desc)]) == :pass
    end
  end

  describe "facts_block/1" do
    test "nil for an unremarkable batch" do
      assert BatchShape.facts_block([add("Build the parser"), add("Ship v1.2")]) == nil
    end

    test "prints every nonzero fact" do
      ops = [
        add("docs/a.md", String.duplicate("y", 2_000)),
        add("Work item", "- [ ] a\n- [ ] b")
      ]

      block = BatchShape.facts_block(ops)
      assert block =~ "Server-computed shape facts:"
      assert block =~ "1 of 2 new task titles look like file paths/names."
      assert block =~ "whole-file sized"
      assert block =~ "2 markdown-checkbox lines sit inside 1 new descriptions."
    end

    test "numbered-checkbox lines land in the checkbox fact (m03.04 2.9.2)" do
      ops = [add("Worklist", "10. [X] audit the pattern\n11. [ ] fix it\n12) [x] verify")]

      assert BatchShape.facts_block(ops) =~
               "3 markdown-checkbox lines sit inside 1 new descriptions."
    end

    test "the checkbox fact prints once, facts only — no ask rides the record (m03.04 2.8.4.1)" do
      block = BatchShape.facts_block([add("Work item", "- [ ] a\n- [ ] b")])

      assert length(String.split(block, "markdown-checkbox lines")) == 2
      refute block =~ "Checklists are what DoItList turns into tasks"
    end

    test "an initiative add with index_style set prints the sets line" do
      ops = [
        %{
          "op" => "add",
          "type" => "initiative",
          "lid" => "i",
          "data" => %{"name" => "Plan", "index_style" => "numerical"}
        },
        add("Build the parser")
      ]

      block = BatchShape.facts_block(ops)
      assert block =~ "Server-computed shape facts:"
      assert block =~ ~s(- New Initiative "Plan" sets index_style: numerical.)
    end

    test "an initiative add without index_style prints the unset fact — always notable" do
      ops = [
        %{"op" => "add", "type" => "initiative", "lid" => "i", "data" => %{"name" => "Plan"}}
      ]

      assert BatchShape.facts_block(ops) =~
               ~s(- New Initiative "Plan" leaves index_style unset — tasks render unnumbered.)
    end

    test "an initiative add never counts toward the task-shape facts" do
      # A pathlike initiative NAME is not a pathlike task title; only the
      # index_style fact prints.
      ops = [%{"op" => "add", "type" => "initiative", "data" => %{"name" => "a/b.md"}}]
      block = BatchShape.facts_block(ops)
      refute block =~ "task titles"
      assert block =~ ~s(- New Initiative "a/b.md" leaves index_style unset)
    end
  end

  describe "open-only import fact (m03.04 2.8.6)" do
    test "an import-scale batch with zero done adds states the fact — verdict unmoved" do
      ops = for i <- 1..12, do: add("Item #{i}")

      assert BatchShape.open_only_adds(ops) == 12
      assert BatchShape.facts_block(ops) =~ "- All 12 new tasks arrive open — none marked done."
      assert BatchShape.classify(ops) == :pass
    end

    test "any done add — `done: true` or `status: \"done\"` — drops the fact" do
      open = for i <- 1..11, do: add("Item #{i}")

      for done_data <- [%{"done" => true}, %{"status" => "done"}] do
        data = Map.merge(%{"initiative_lid" => "i", "title" => "Shipped"}, done_data)
        ops = [%{"op" => "add", "type" => "task", "data" => data} | open]

        assert BatchShape.open_only_adds(ops) == nil
        assert BatchShape.facts_block(ops) == nil
        assert BatchShape.classify(ops) == :pass
      end
    end

    test "a sub-floor all-open batch is not notable" do
      ops = for i <- 1..9, do: add("Item #{i}")

      assert BatchShape.open_only_adds(ops) == nil
      assert BatchShape.facts_block(ops) == nil
    end
  end
end
