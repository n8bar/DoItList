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
      assert message =~ "`settled` entry quoting their instruction"
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

  describe "classify/1 checklist hold" do
    test "one checklist-bearing description holds with the subtasks question" do
      ops = [add("Setup", "Steps:\n- [ ] install\n- [ ] configure"), add("Cleanup")]

      assert {:hold, question} = BatchShape.classify(ops)
      assert question =~ "2 markdown-checkbox lines"
      assert question =~ "subtasks"
      assert question =~ "apply keeps them as description prose"
    end

    test "a single stray checkbox line is noise — passes" do
      assert BatchShape.classify([add("Setup", "- [x] done already")]) == :pass
    end
  end

  describe "facts_block/1" do
    test "nil for an unremarkable batch" do
      assert BatchShape.facts_block([add("Build the parser"), add("Ship v1.2")]) == nil
    end

    test "prints every nonzero fact plus the checklist question when present" do
      ops = [
        add("docs/a.md", String.duplicate("y", 2_000)),
        add("Work item", "- [ ] a\n- [ ] b")
      ]

      block = BatchShape.facts_block(ops)
      assert block =~ "Server-computed shape facts:"
      assert block =~ "1 of 2 new task titles look like file paths/names."
      assert block =~ "whole-file sized"
      assert block =~ "2 markdown-checkbox lines sit inside 1 new descriptions."
      assert block =~ "subtasks"
    end

    test "non-task ops are ignored" do
      ops = [%{"op" => "add", "type" => "initiative", "data" => %{"name" => "a/b.md"}}]
      assert BatchShape.facts_block(ops) == nil
    end
  end
end
