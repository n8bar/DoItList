defmodule DoIt.Tasks.TreeTest do
  use ExUnit.Case, async: true

  alias DoIt.Tasks.Tree

  # Plain maps stand in for Task structs — Tree only touches :id and :children.
  defp tnode(id, children \\ [], extra \\ %{}) do
    Map.merge(%{id: id, title: "t#{id}", children: children}, extra)
  end

  describe "merge/2" do
    test "replaces fields of matching nodes and keeps their children" do
      tree = [tnode(1, [tnode(2, [tnode(3)])]), tnode(4)]
      fresh = [%{id: 2, title: "fresh", children: []}]

      [one, four] = Tree.merge(tree, fresh)
      [two] = one.children

      assert two.title == "fresh"
      assert [%{id: 3}] = two.children
      assert four.title == "t4"
    end

    test "ignores ids not present in the tree" do
      tree = [tnode(1)]
      assert Tree.merge(tree, [%{id: 99, title: "ghost", children: []}]) == tree
    end

    test "merges several lineage nodes at once (leaf + ancestors)" do
      tree = [tnode(1, [tnode(2, [tnode(3)])])]

      fresh = [
        %{id: 1, title: "root'", children: []},
        %{id: 3, title: "leaf'", children: []}
      ]

      [one] = Tree.merge(tree, fresh)
      [two] = one.children
      [three] = two.children

      assert one.title == "root'"
      assert two.title == "t2"
      assert three.title == "leaf'"
    end
  end

  describe "reorder_children/3" do
    test "re-keys a nested parent's child order, keeping subtrees" do
      tree = [tnode(1, [tnode(2, [tnode(20)]), tnode(3), tnode(4)])]

      [one] = Tree.reorder_children(tree, 1, [4, 2, 3])

      assert Enum.map(one.children, & &1.id) == [4, 2, 3]
      assert [%{id: 20}] = Enum.at(one.children, 1).children
    end

    test ":root re-keys the top-level list" do
      tree = [tnode(1), tnode(2), tnode(3)]
      assert tree |> Tree.reorder_children(:root, [3, 1, 2]) |> Enum.map(& &1.id) == [3, 1, 2]
    end

    test "children missing from the order keep relative order at the end" do
      tree = [tnode(1, [tnode(2), tnode(3), tnode(4)])]

      [one] = Tree.reorder_children(tree, 1, [4])

      assert Enum.map(one.children, & &1.id) == [4, 2, 3]
    end

    test "unknown parent leaves the tree unchanged" do
      tree = [tnode(1, [tnode(2)])]
      assert Tree.reorder_children(tree, 99, [2]) == tree
    end
  end
end
