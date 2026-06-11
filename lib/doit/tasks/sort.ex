defmodule DoIt.Tasks.Sort do
  @moduledoc """
  Pure sibling-sort engine. Reorders a list of sibling `Task` structs
  according to a sort mode and direction, then assigns fresh `sort_order`
  values spaced with a fixed gap so subsequent single-row reorders stay
  cheap.

  Does not touch the database — callers persist the returned tasks.

  ## Modes (natural direction)

  * `"manual"` — no-op; input returned unchanged regardless of `reverse?`
  * `"alphabetical"` — title ascending, case-insensitive
  * `"completion"` — completion % ascending (least complete first);
    `done` sorts as 100 by construction
  * `"priority"` — `high` → `normal` → `low`
  * `"created"` — `inserted_at` ascending (oldest first)
  * `"updated"` — `updated_at` descending (most recent first)

  Passing `reverse?: true` flips the natural direction. The `id`
  tiebreaker stays ascending in both directions so output is fully
  deterministic regardless of input order.
  """

  alias DoIt.Tasks.Task

  @sort_gap 1000

  # Modes with a real comparator. Anything outside this set (e.g. a `sort_mode`
  # left over from a renamed/removed scheme) is treated as manual rather than
  # allowed to crash the caller's transaction — a stray value must never take
  # down a move or resort.
  @known_modes ~w(alphabetical completion priority created updated)

  def sort_gap, do: @sort_gap

  @doc "Reorder `children` by `mode` (optionally reversed) and stamp new `sort_order` values."
  def apply(children, mode, reverse? \\ false)

  def apply([], _mode, _reverse?), do: []
  def apply([_one] = list, _mode, _reverse?), do: list

  def apply(children, mode, reverse?) when mode in @known_modes and is_list(children) do
    children
    |> Enum.sort(&compare(&1, &2, mode, reverse?))
    |> renumber()
  end

  # "manual" and any unrecognized mode: keep the existing order untouched.
  def apply(children, _mode, _reverse?) when is_list(children), do: children

  defp renumber(children) do
    children
    |> Enum.with_index(1)
    |> Enum.map(fn {task, idx} -> %{task | sort_order: idx * @sort_gap} end)
  end

  defp compare(a, b, mode, reverse?) do
    case mode_compare(a, b, mode) do
      :eq -> a.id <= b.id
      :lt -> not reverse?
      :gt -> reverse?
    end
  end

  defp mode_compare(%Task{} = a, %Task{} = b, "alphabetical"),
    do: cmp(downcase(a.title), downcase(b.title))

  defp mode_compare(%Task{} = a, %Task{} = b, "completion"),
    do: cmp(completion_value(a), completion_value(b))

  defp mode_compare(%Task{} = a, %Task{} = b, "priority"),
    do: cmp(priority_rank(a.priority), priority_rank(b.priority))

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

  # The visible roll-up % — the same number the row's underbar shows.
  defp completion_value(%Task{status: "done"}), do: 100
  defp completion_value(%Task{computed_progress: cp}) when is_integer(cp), do: cp
  defp completion_value(%Task{manual_progress: mp}) when is_integer(mp), do: mp
  defp completion_value(_), do: 0

  defp priority_rank("high"), do: 0
  defp priority_rank("normal"), do: 1
  defp priority_rank("low"), do: 2
  defp priority_rank(_), do: 3
end
