defmodule DoIt.Tasks.Sort do
  @moduledoc """
  Pure sibling-sort engine. Reorders a list of sibling `Task` structs
  according to a sort mode and assigns fresh `sort_order` values spaced
  with a fixed gap so subsequent single-row reorders stay cheap.

  Does not touch the database — callers persist the returned tasks.

  ## Modes

  * `"manual"` — no-op; input returned unchanged
  * `"alphabetical"` — title ascending, case-insensitive
  * `"status"` — `open` → `in_progress` → `done` (incomplete first)
  * `"computed_progress"` — descending (most progress first)
  * `"priority"` — `high` → `normal` → `low`
  * `"weight"` — descending (heaviest first)
  * `"created"` — `inserted_at` ascending (oldest first)
  * `"updated"` — `updated_at` descending (most recent first)

  All comparisons fall back to `id` ascending as a stable tiebreaker.
  """

  alias DoIt.Tasks.Task

  @sort_gap 1000

  def sort_gap, do: @sort_gap

  @doc "Reorder `children` by `mode` and stamp new `sort_order` values."
  def apply(children, mode)

  def apply([], _mode), do: []
  def apply([_one] = list, _mode), do: list
  def apply(children, "manual"), do: children

  def apply(children, mode) when is_list(children) do
    children
    |> Enum.sort(&compare(&1, &2, mode))
    |> renumber()
  end

  defp renumber(children) do
    children
    |> Enum.with_index(1)
    |> Enum.map(fn {task, idx} -> %{task | sort_order: idx * @sort_gap} end)
  end

  defp compare(a, b, mode) do
    case mode_compare(a, b, mode) do
      :lt -> true
      :gt -> false
      :eq -> a.id <= b.id
    end
  end

  defp mode_compare(%Task{} = a, %Task{} = b, "alphabetical"),
    do: cmp(downcase(a.title), downcase(b.title))

  defp mode_compare(%Task{} = a, %Task{} = b, "status"),
    do: cmp(status_rank(a.status), status_rank(b.status))

  defp mode_compare(%Task{} = a, %Task{} = b, "computed_progress"),
    do: cmp(b.computed_progress, a.computed_progress)

  defp mode_compare(%Task{} = a, %Task{} = b, "priority"),
    do: cmp(priority_rank(a.priority), priority_rank(b.priority))

  defp mode_compare(%Task{} = a, %Task{} = b, "weight"),
    do: Decimal.compare(b.weight, a.weight)

  defp mode_compare(%Task{} = a, %Task{} = b, "created"),
    do: datetime_cmp(a.inserted_at, b.inserted_at)

  defp mode_compare(%Task{} = a, %Task{} = b, "updated"),
    do: datetime_cmp(b.updated_at, a.updated_at)

  defp cmp(x, x), do: :eq
  defp cmp(x, y) when x < y, do: :lt
  defp cmp(_, _), do: :gt

  defp datetime_cmp(a, b) do
    case DateTime.compare(a, b) do
      :eq -> :eq
      :lt -> :lt
      :gt -> :gt
    end
  end

  defp downcase(nil), do: ""
  defp downcase(s) when is_binary(s), do: String.downcase(s)

  defp status_rank("open"), do: 0
  defp status_rank("in_progress"), do: 1
  defp status_rank("done"), do: 2
  defp status_rank(_), do: 3

  defp priority_rank("high"), do: 0
  defp priority_rank("normal"), do: 1
  defp priority_rank("low"), do: 2
  defp priority_rank(_), do: 3
end
