defmodule DoIt.Tasks.Progress do
  @moduledoc """
  Pure progress roll-up rules (ProductSpec § Roll-up Progress).

  Operates on `%DoIt.Tasks.Task{}` structs whose `:children` association is
  preloaded recursively (or set to `[]` for leaves). No Repo access — easy to
  test with hand-built structs.

  Rules — **leaf average** (AbstractSpoon-style default):
    * Leaf  → `manual_progress` (clamped to 0..100). Leaf `status: "done"`
      snaps to 100.
    * Branch → plain average over **all descendant leaves** — every leaf
      counts one unit, wherever it sits in the subtree:

          sum(leaf_progress) / leaf_count

      A subtree's pull on its ancestors is its leaf count; decomposing a
      branch further is how it comes to matter more (ProductSpec § Durable
      Principles). (The original single-level average — each direct child
      one unit — is available as the `:single_level` mode, a per-initiative
      setting.)
    * Branch status does NOT snap to 100; progress is always derived from
      leaves so a `done` parent that gains an incomplete child reflects the
      truth. Status reconciliation lives in `DoIt.Tasks`.
    * A branch with no children is treated as a leaf.

  Result is always an integer in 0..100.
  """

  alias DoIt.Tasks.Task

  @spec compute(Task.t(), :leaf_average | :single_level) :: integer()
  def compute(task, mode \\ :leaf_average)
  def compute(%Task{} = task, :leaf_average), do: task |> leaf_values() |> average()
  def compute(%Task{} = task, :single_level), do: single_level_value(task)

  @doc """
  Compute every node's rolled-up value in one pass over an assembled tree
  (a list of root nodes). Returns `%{task_id => value}` — the whole-initiative
  reconcile diffs persisted values against this map. One traversal: leaf
  averages aren't derivable per-level from children's persisted percentages
  (they'd also need each child's leaf count), so roll-up always starts
  from the leaves.
  """
  @spec compute_all([Task.t()], :leaf_average | :single_level) :: %{integer() => integer()}
  def compute_all(tree, mode \\ :leaf_average)

  def compute_all(tree, :leaf_average) when is_list(tree) do
    Enum.reduce(tree, %{}, fn node, acc -> elem(evaluate_into(node, acc), 1) end)
  end

  def compute_all(tree, :single_level) when is_list(tree) do
    Enum.reduce(tree, %{}, fn node, acc -> elem(single_level_into(node, acc), 1) end)
  end

  # --- Leaf average -----------------------------------------------------------

  # All descendant leaf values under a node (the node's own value if it's a leaf).
  defp leaf_values(%Task{children: kids}) when is_list(kids) and kids != [] do
    Enum.flat_map(kids, &leaf_values/1)
  end

  defp leaf_values(%Task{} = task), do: [leaf_progress(task)]

  # Same traversal, accumulating every node's value into a map.
  # Returns {leaf_values, acc}.
  defp evaluate_into(%Task{children: kids} = task, acc) when is_list(kids) and kids != [] do
    {values, acc} =
      Enum.reduce(kids, {[], acc}, fn child, {values, acc} ->
        {child_values, acc} = evaluate_into(child, acc)
        {values ++ child_values, acc}
      end)

    {values, Map.put(acc, task.id, average(values))}
  end

  defp evaluate_into(%Task{} = task, acc) do
    value = leaf_progress(task)
    {[value], Map.put(acc, task.id, value)}
  end

  # --- Single-level average mode (per-initiative setting) ---------------------
  # The original formula: a branch is the plain average of its DIRECT
  # children's rolled-up values — each child one unit regardless of how many
  # leaves it contains.

  defp single_level_value(%Task{children: kids}) when is_list(kids) and kids != [] do
    kids |> Enum.map(&single_level_value/1) |> average()
  end

  defp single_level_value(%Task{} = task), do: leaf_progress(task)

  defp single_level_into(%Task{children: kids} = task, acc) when is_list(kids) and kids != [] do
    {values, acc} =
      Enum.reduce(kids, {[], acc}, fn child, {values, acc} ->
        {value, acc} = single_level_into(child, acc)
        {[value | values], acc}
      end)

    value = average(values)
    {value, Map.put(acc, task.id, value)}
  end

  defp single_level_into(%Task{} = task, acc) do
    value = leaf_progress(task)
    {value, Map.put(acc, task.id, value)}
  end

  # --- Shared -----------------------------------------------------------------

  defp leaf_progress(%Task{status: "done"}), do: 100
  defp leaf_progress(%Task{manual_progress: mp}), do: clamp(mp)

  defp average([]), do: 0

  defp average(values) do
    values
    |> Enum.sum()
    |> Decimal.new()
    |> Decimal.div(Decimal.new(length(values)))
    |> Decimal.round(0, :half_up)
    |> Decimal.to_integer()
    |> clamp()
  end

  defp clamp(nil), do: 0
  defp clamp(n) when n < 0, do: 0
  defp clamp(n) when n > 100, do: 100
  defp clamp(n) when is_integer(n), do: n
end
