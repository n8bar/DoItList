defmodule DoIt.Tasks.Progress do
  @moduledoc """
  Pure progress roll-up rules.

  Operates on `%DoIt.Tasks.Task{}` structs whose `:children` association is
  preloaded (or set to `[]` for leaves). No Repo access — easy to test with
  hand-built structs.

  Rules:
    * Leaf  → `manual_progress` (clamped to 0..100). Leaf `status: "done"`
      snaps to 100.
    * Branch (has at least one usable child) → weighted average of child
      rolled-up progress:
          sum(child_progress * child_weight) / sum(child_weight)
      Branch status does NOT snap to 100; progress is always derived from
      children so a `done` parent that gains an incomplete child reflects
      the truth. Status reconciliation lives in `DoIt.Tasks` (the
      check/uncheck-ancestors helpers), not here.
    * Children with non-positive weight are ignored.
    * If no usable children exist, treat as a leaf.

  Result is always an integer in 0..100.
  """

  alias DoIt.Tasks.Task

  @spec compute(Task.t()) :: integer()
  def compute(%Task{children: children} = task) when is_list(children) do
    case usable_children(children) do
      [] -> leaf_progress(task)
      kids -> weighted_average(kids, &compute/1)
    end
  end

  # When :children is not preloaded, treat as leaf.
  def compute(%Task{} = task), do: leaf_progress(task)

  @doc """
  Compute progress for a task whose direct `:children` are loaded but whose
  *grandchildren* are not. Each child's already-persisted `computed_progress`
  is trusted as the rolled-up value for its subtree — so this function is the
  one to use when walking up an ancestor chain bottom-up, after each child has
  already had its progress refreshed.
  """
  @spec compute_for_branch(Task.t()) :: integer()
  def compute_for_branch(%Task{children: children} = task) when is_list(children) do
    case usable_children(children) do
      [] -> leaf_progress(task)
      kids -> weighted_average(kids, &child_persisted_progress/1)
    end
  end

  def compute_for_branch(%Task{} = task), do: leaf_progress(task)

  defp leaf_progress(%Task{status: "done"}), do: 100
  defp leaf_progress(%Task{manual_progress: mp}), do: clamp(mp)

  defp child_persisted_progress(%Task{status: "done"}), do: 100
  defp child_persisted_progress(%Task{computed_progress: cp}) when is_integer(cp), do: clamp(cp)
  defp child_persisted_progress(%Task{manual_progress: mp}), do: clamp(mp)

  defp usable_children(children) do
    Enum.filter(children, fn child ->
      w = to_decimal(child.weight)
      Decimal.compare(w, Decimal.new(0)) == :gt
    end)
  end

  defp weighted_average(children, progress_fun) do
    {weighted_sum, weight_sum} =
      Enum.reduce(children, {Decimal.new(0), Decimal.new(0)}, fn child, {ws, w_total} ->
        progress = child |> progress_fun.() |> Decimal.new()
        weight = to_decimal(child.weight)

        {Decimal.add(ws, Decimal.mult(progress, weight)), Decimal.add(w_total, weight)}
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
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp to_decimal(s) when is_binary(s), do: Decimal.new(s)

  defp clamp(nil), do: 0
  defp clamp(n) when n < 0, do: 0
  defp clamp(n) when n > 100, do: 100
  defp clamp(n) when is_integer(n), do: n
end
