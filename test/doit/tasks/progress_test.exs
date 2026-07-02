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
      children: []
    }
  end

  defp branch(children, opts \\ []) do
    %Task{
      id: opts[:id] || :erlang.unique_integer([:positive]),
      manual_progress: opts[:manual_progress] || 0,
      status: opts[:status] || "open",
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
      # Single-level average said 50; leaf average dilutes: (100 + 0*4)/5 = 20.
      tree = branch([leaf(100), branch([leaf(0), leaf(0), leaf(0), leaf(0)])])
      assert Progress.compute(tree) == 20
    end

    test "Example B: sibling branches of different sizes" do
      # Single-level average said 50; leaf average: (100+100+0)/3 ≈ 67.
      tree = branch([branch([leaf(100), leaf(100)]), branch([leaf(0)])])
      assert Progress.compute(tree) == 67
    end

    test "Example C: flat branches agree with the single-level method" do
      assert Progress.compute(branch([leaf(40), leaf(80)])) == 60
    end

    test "decomposition is the weighting: a bigger subtree pulls harder" do
      # The four-leaf branch carries four units against the lone leaf's one
      # (ProductSpec § Durable Principles — no weight attribute).
      tree = branch([leaf(100), branch([leaf(0), leaf(0), leaf(0), leaf(0)])])
      assert Progress.compute(tree) == 20

      bigger = branch([leaf(100), branch(List.duplicate(leaf(0), 9))])
      assert Progress.compute(bigger) == 10
    end

    test "compute_all matches compute for every node" do
      inner = branch([leaf(0), leaf(100)], id: 2)
      root = branch([inner, leaf(40, id: 3)], id: 1)

      values = Progress.compute_all([root])

      assert values[1] == Progress.compute(root)
      assert values[2] == Progress.compute(inner)
      assert values[3] == 40
      assert values[1] == 47
    end
  end

  describe "single-level mode (per-initiative setting)" do
    test "each direct child counts as one unit, however many leaves it holds" do
      grandchildren = branch([leaf(0), leaf(100)])
      tree = branch([grandchildren, leaf(0)])
      assert Progress.compute(tree, :single_level) == 25
      assert Progress.compute(tree) == 33
    end

    test "compute_all in single-level mode matches compute for every node" do
      inner = branch([leaf(0), leaf(100)], id: 2)
      root = branch([inner, leaf(40, id: 3)], id: 1)

      values = Progress.compute_all([root], :single_level)

      assert values[1] == Progress.compute(root, :single_level)
      assert values[2] == 50
      assert values[3] == 40
    end
  end

  describe "branch tasks" do
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
      # the leaf average (here: 0).
      tree = branch([leaf(0), leaf(0)], manual_progress: 99)
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

    test "marking a deep child done forces it to 100, propagating upward" do
      # The marked-done leaf is 100 by status, others are 0 → 33.
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
        children: %Ecto.Association.NotLoaded{}
      }

      tree = branch([child])
      assert Progress.compute(tree) == 60
    end
  end

  # `leaf_value/1` and `average/1` are the two building blocks a chain-scoped
  # recompute (`DoIt.Tasks`) composes directly against rows it queries
  # itself — plain maps off a `select: %{status: ..., manual_progress: ...}`
  # projection, not full `%Task{}` structs. `compute/2` and `compute_all/2`
  # above already exercise the same logic via the whole-tree walk; these
  # pin that the public entry points work standalone, against the shape a
  # scoped caller actually has in hand.
  describe "leaf_value/1 (public building block)" do
    test "done snaps to 100 regardless of manual_progress" do
      assert Progress.leaf_value(%{status: "done", manual_progress: 12}) == 100
    end

    test "open/in_progress uses manual_progress, clamped" do
      assert Progress.leaf_value(%{status: "open", manual_progress: 42}) == 42
      assert Progress.leaf_value(%{status: "in_progress", manual_progress: -5}) == 0
      assert Progress.leaf_value(%{status: "open", manual_progress: 150}) == 100
    end

    test "works against a plain map, not just a %Task{}" do
      assert Progress.leaf_value(%{status: "open", manual_progress: 33}) == 33
    end
  end

  describe "average/1 (public building block)" do
    test "empty list averages to 0" do
      assert Progress.average([]) == 0
    end

    test "rounds half-up and clamps" do
      assert Progress.average([1, 2]) == 2
      assert Progress.average([100, 100, 100]) == 100
    end
  end
end
