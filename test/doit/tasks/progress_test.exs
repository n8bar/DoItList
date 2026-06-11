defmodule DoIt.Tasks.ProgressTest do
  @moduledoc """
  Pure tests for the progress roll-up rules. These do NOT touch the database;
  they exercise `DoIt.Tasks.Progress` against hand-built `%Task{}` structs.
  """
  use ExUnit.Case, async: true

  alias DoIt.Tasks.Task
  alias DoIt.Tasks.Progress

  defp leaf(progress, opts \\ []) do
    %Task{
      id: opts[:id] || :erlang.unique_integer([:positive]),
      manual_progress: progress,
      status: opts[:status] || "open",
      weight: Decimal.new(to_string(opts[:weight] || "1.0")),
      children: []
    }
  end

  defp branch(children, opts \\ []) do
    %Task{
      id: opts[:id] || :erlang.unique_integer([:positive]),
      manual_progress: opts[:manual_progress] || 0,
      status: opts[:status] || "open",
      weight: Decimal.new(to_string(opts[:weight] || "1.0")),
      children: children
    }
  end

  describe "leaf tasks" do
    test "uses manual_progress" do
      assert Progress.compute(leaf(0)) == 0
      assert Progress.compute(leaf(42)) == 42
      assert Progress.compute(leaf(100)) == 100
    end

    test "clamps out-of-range values" do
      assert Progress.compute(leaf(-5)) == 0
      assert Progress.compute(leaf(150)) == 100
    end

    test "nil progress is treated as 0" do
      assert Progress.compute(%Task{manual_progress: nil, status: "open", children: []}) == 0
    end

    test "status done forces 100 even if manual_progress is lower" do
      assert Progress.compute(leaf(20, status: "done")) == 100
    end
  end

  describe "leaf average (design examples, .03.09.01)" do
    test "Example A: a one-leaf sibling vs a four-leaf branch" do
      # First-generation said 50; leaf average dilutes: (100 + 0*4)/5 = 20.
      tree = branch([leaf(100), branch([leaf(0), leaf(0), leaf(0), leaf(0)])])
      assert Progress.compute(tree) == 20
    end

    test "Example B: sibling branches of different sizes" do
      # First-generation said 50; leaf average: (100+100+0)/3 ≈ 67.
      tree = branch([branch([leaf(100), leaf(100)]), branch([leaf(0)])])
      assert Progress.compute(tree) == 67
    end

    test "Example C: flat branches agree with the first-generation method" do
      assert Progress.compute(branch([leaf(40), leaf(80)])) == 60
    end

    test "an intermediate branch's weight scales its whole subtree" do
      # The weighted branch's leaves each carry mass 2 on the way up:
      # (100*1 + 0*2*4) / (1 + 8) ≈ 11.
      tree = branch([leaf(100), branch([leaf(0), leaf(0), leaf(0), leaf(0)], weight: 2)])
      assert Progress.compute(tree) == 11
    end

    test "compute_all matches compute for every node, including zero-weight subtrees" do
      inner = branch([leaf(0), leaf(100)], id: 2)
      skipped = branch([leaf(70)], id: 4, weight: 0)
      root = branch([inner, leaf(40, id: 3), skipped], id: 1)

      values = Progress.compute_all([root])

      assert values[1] == Progress.compute(root)
      assert values[2] == Progress.compute(inner)
      assert values[3] == 40
      # Zero-weight subtree is excluded from the parent's average but its own
      # value still reconciles.
      assert values[4] == 70
      assert values[1] == 47
    end
  end

  describe "branch tasks (default equal weight)" do
    test "averages two leaves" do
      tree = branch([leaf(0), leaf(100)])
      assert Progress.compute(tree) == 50
    end

    test "averages three leaves" do
      tree = branch([leaf(10), leaf(50), leaf(90)])
      assert Progress.compute(tree) == 50
    end

    test "rounds half-up" do
      # (33 + 34) / 2 = 33.5 → 34
      tree = branch([leaf(33), leaf(34)])
      assert Progress.compute(tree) == 34
    end

    test "ignores manual_progress on a branch" do
      # branch's own manual_progress is 99, but since it has children, we use
      # the weighted average (here: 0).
      tree = branch([leaf(0), leaf(0)], manual_progress: 99)
      assert Progress.compute(tree) == 0
    end
  end

  describe "branch tasks (weighted)" do
    test "weighted average with integer weights" do
      # 25*1 + 75*3 = 25 + 225 = 250 ; total weight = 4 ; result = 62.5 → 63
      tree = branch([leaf(25, weight: 1), leaf(75, weight: 3)])
      assert Progress.compute(tree) == 63
    end

    test "weighted average with decimal weights" do
      tree = branch([leaf(40, weight: "0.5"), leaf(80, weight: "1.5")])
      # (40*0.5 + 80*1.5) / 2.0 = (20 + 120) / 2 = 70
      assert Progress.compute(tree) == 70
    end

    test "weight of 0 means the child is ignored" do
      tree = branch([leaf(0, weight: 0), leaf(100, weight: 1)])
      assert Progress.compute(tree) == 100
    end

    test "if every child has weight 0, falls back to 0" do
      tree = branch([leaf(50, weight: 0), leaf(80, weight: 0)])
      assert Progress.compute(tree) == 0
    end
  end

  describe "recursive roll-up (leaf average)" do
    test "grandchildren propagate up two levels" do
      # Leaves: 0, 100 (inside the sub-branch) and 0 — every leaf counts
      # equally wherever it sits → 100/3 = 33.
      grandchildren = branch([leaf(0), leaf(100)])
      tree = branch([grandchildren, leaf(0)])
      assert Progress.compute(tree) == 33
    end

    test "weighted recursive roll-up" do
      # left subtree: leaves 100,100 — each passes through the branch's
      # weight 3 on the way up (path product) → mass 3 apiece
      # right leaf: 0, weight 1
      # root: (100*3 + 100*3 + 0*1) / 7 ≈ 86
      left = branch([leaf(100), leaf(100)], weight: 3)
      right = leaf(0, weight: 1)
      root = branch([left, right])
      assert Progress.compute(root) == 86
    end

    test "marking a deep child done forces it to 100, propagating upward" do
      # The marked-done leaf is 100 by status, others are 0. Equal weights → 33.
      child_done = leaf(0, status: "done")
      tree = branch([leaf(0), leaf(0), child_done])
      assert Progress.compute(tree) == 33
    end

    test "branch with status done derives from children — status does NOT snap to 100" do
      # Branches always reflect their children's progress. A stale `status: done`
      # on a branch (e.g. a leaf that just gained children via a move) no longer
      # masks the truth. Status reconciliation lives in `DoIt.Tasks`.
      tree = branch([leaf(0), leaf(0)], status: "done")
      assert Progress.compute(tree) == 0
    end

    test "leaf with status done still snaps to 100" do
      assert Progress.compute(leaf(0, status: "done")) == 100
    end
  end

  describe "edge cases" do
    test "branch with a single child reflects that child" do
      assert Progress.compute(branch([leaf(42)])) == 42
    end

    test "child with non-loaded :children association is treated as a leaf" do
      child = %Task{
        manual_progress: 60,
        status: "open",
        weight: Decimal.new("1.0"),
        children: %Ecto.Association.NotLoaded{}
      }

      tree = branch([child])
      assert Progress.compute(tree) == 60
    end
  end
end
