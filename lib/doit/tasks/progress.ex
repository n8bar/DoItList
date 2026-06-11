defmodule DoIt.Tasks.Progress do
  @moduledoc """
  Pure progress roll-up rules (ProductSpec § Roll-up Progress).

  Operates on `%DoIt.Tasks.Task{}` structs whose `:children` association is
  preloaded recursively (or set to `[]` for leaves). No Repo access — easy to
  test with hand-built structs.

  Rules — **leaf average** (AbstractSpoon-style default):
    * Leaf  → `manual_progress` (clamped to 0..100). Leaf `status: "done"`
      snaps to 100.
    * Branch → weighted average over **all descendant leaves** — every leaf
      counts, wherever it sits in the subtree:

          sum(leaf_progress * leaf_path_weight) / sum(leaf_path_weight)

      where `leaf_path_weight` is the product of the weights along the path
      from the branch's direct child down to the leaf. With everything at the
      default weight this is a plain average of the leaves; weighting an
      intermediate branch scales its whole subtree's leaves on the way up.
      (The original first-generation average — each direct child one unit —
      returns later as a per-initiative setting; see BACKLOG.)
    * Branch status does NOT snap to 100; progress is always derived from
      leaves so a `done` parent that gains an incomplete child reflects the
      truth. Status reconciliation lives in `DoIt.Tasks`.
    * Children with non-positive weight are ignored (their whole subtree).
    * A branch with no usable children is treated as a leaf.

  Result is always an integer in 0..100.
  """

  alias DoIt.Tasks.Task

  @spec compute(Task.t()) :: integer()
  def compute(%Task{} = task), do: task |> evaluate() |> elem(0)

  @doc """
  Compute every node's rolled-up value in one pass over an assembled tree
  (a list of root nodes). Returns `%{task_id => value}` — the whole-initiative
  reconcile diffs persisted values against this map. One traversal: leaf
  averages aren't derivable per-level from children's persisted percentages
  (they'd also need each child's leaf-weight mass), so roll-up always starts
  from the leaves.
  """
  @spec compute_all([Task.t()]) :: %{integer() => integer()}
  def compute_all(tree) when is_list(tree) do
    Enum.reduce(tree, %{}, fn node, acc -> elem(evaluate_into(node, acc), 1) end)
  end

  # --- Evaluation -------------------------------------------------------------

  # {value, leaf_pairs} for a node. `leaf_pairs` is a list of
  # {leaf_value, mass} Decimals for every usable leaf under the node — masses
  # exclusive of the node's own weight (a task's weight applies where it is
  # aggregated, i.e. at its parent). `nil` pairs marks the node as a leaf.
  defp evaluate(%Task{children: children} = task) when is_list(children) do
    case usable_children(children) do
      [] ->
        {leaf_progress(task), nil}

      kids ->
        pairs = Enum.flat_map(kids, &child_pairs/1)
        {pairs_average(pairs), pairs}
    end
  end

  defp evaluate(%Task{} = task), do: {leaf_progress(task), nil}

  defp child_pairs(%Task{} = child) do
    w = to_decimal(child.weight)

    case evaluate(child) do
      {value, nil} -> [{Decimal.new(value), w}]
      {_value, pairs} -> Enum.map(pairs, fn {v, m} -> {v, Decimal.mult(m, w)} end)
    end
  end

  # Same traversal, accumulating every node's value into a map.
  defp evaluate_into(%Task{children: children} = task, acc) when is_list(children) do
    case usable_children(children) do
      [] ->
        value = leaf_progress(task)
        {{value, nil}, collect_skipped(children, Map.put(acc, task.id, value))}

      kids ->
        {pairs, acc} =
          Enum.reduce(kids, {[], acc}, fn child, {pairs, acc} ->
            w = to_decimal(child.weight)
            {{value, child_pairs}, acc} = evaluate_into(child, acc)

            new_pairs =
              case child_pairs do
                nil -> [{Decimal.new(value), w}]
                list -> Enum.map(list, fn {v, m} -> {v, Decimal.mult(m, w)} end)
              end

            {pairs ++ new_pairs, acc}
          end)

        acc = collect_skipped(children -- kids, acc)
        value = pairs_average(pairs)
        {{value, pairs}, Map.put(acc, task.id, value)}
    end
  end

  defp evaluate_into(%Task{} = task, acc) do
    value = leaf_progress(task)
    {{value, nil}, Map.put(acc, task.id, value)}
  end

  # Zero-weight subtrees don't contribute to any average, but their own
  # values still reconcile (a zero-weight branch shows its own roll-up).
  defp collect_skipped(children, acc) do
    Enum.reduce(children, acc, fn child, acc ->
      if Map.has_key?(acc, child.id), do: acc, else: elem(evaluate_into(child, acc), 1)
    end)
  end

  defp leaf_progress(%Task{status: "done"}), do: 100
  defp leaf_progress(%Task{manual_progress: mp}), do: clamp(mp)

  defp usable_children(children) do
    Enum.filter(children, fn child ->
      w = to_decimal(child.weight)
      Decimal.compare(w, Decimal.new(0)) == :gt
    end)
  end

  defp pairs_average([]), do: 0

  defp pairs_average(pairs) do
    {weighted_sum, weight_sum} =
      Enum.reduce(pairs, {Decimal.new(0), Decimal.new(0)}, fn {v, m}, {ws, w_total} ->
        {Decimal.add(ws, Decimal.mult(v, m)), Decimal.add(w_total, m)}
      end)

    case Decimal.compare(weight_sum, Decimal.new(0)) do
      :gt ->
        weighted_sum
        |> Decimal.div(weight_sum)
        |> Decimal.round(0, :half_up)
        |> Decimal.to_integer()
        |> clamp()

      _ ->
        0
    end
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(nil), do: Decimal.new(0)
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp to_decimal(s) when is_binary(s), do: Decimal.new(s)

  defp clamp(nil), do: 0
  defp clamp(n) when n < 0, do: 0
  defp clamp(n) when n > 100, do: 100
  defp clamp(n) when is_integer(n), do: n
end
