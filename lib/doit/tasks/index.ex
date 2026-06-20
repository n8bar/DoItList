defmodule DoIt.Tasks.Index do
  @moduledoc """
  Pure positional task-index formatting (m02.07 item 1.7).

  A task's index is derived purely from its position among its siblings at
  every level of the tree — display-only, never stored on the task. Given the
  chain of zero-based sibling positions from the root down to a node
  (e.g. `[0, 2, 1]` = first list → its third child → that child's second
  child) and an index style, `label/2` formats the dotted label for that node.

  Because the label is computed from sibling position, it is automatically
  correct after any reorder or move — the caller recomputes from the tree's
  current order, no bookkeeping required.

  Styles (item 1.7.1):

    * `"outline"`     — alternating `I.A.1.a.i` (per AbstractSpoon's outline
      numbering), cycling roman → alpha → numeric → alpha-lower → roman-lower
      and repeating for deeper levels.
    * `"numerical"`   — `1.1.2` (decimal, one numeric segment per level).
    * `"roman"`       — `I.I.II` (uppercase roman at every level).
    * `"alphabetical"`— `A.A.B` (uppercase letters at every level).
    * `"none"`        — no label (the default).

  The accepted style values (`"none"` is the default).
  """

  @styles ~w(none outline numerical roman alphabetical)

  @doc "The list of accepted style strings."
  def styles, do: @styles

  @doc "The default style."
  def default_style, do: "none"

  @doc "Whether `style` is a recognized index style."
  def valid_style?(style), do: style in @styles

  @doc """
  Format the index label for a node, given its `positions` (zero-based sibling
  positions from the root down to the node) and the `style`.

  Returns `""` for the `"none"` style, an empty position list, or an
  unrecognized style.
  """
  def label(_positions, style) when style in [nil, "none"], do: ""
  def label([], _style), do: ""

  def label(positions, style) when is_list(positions) do
    if valid_style?(style) do
      positions
      |> Enum.with_index()
      |> Enum.map(fn {pos, level} -> segment(style, level, pos) end)
      |> Enum.join(".")
    else
      ""
    end
  end

  # --- Per-segment formatting ------------------------------------------------

  # One numeric segment per level.
  defp segment("numerical", _level, pos), do: Integer.to_string(pos + 1)

  # Uppercase roman at every level.
  defp segment("roman", _level, pos), do: roman_upper(pos)

  # Uppercase letters at every level.
  defp segment("alphabetical", _level, pos), do: alpha_upper(pos)

  # Outline: cycle through five formats by depth, repeating.
  defp segment("outline", level, pos) do
    case rem(level, 5) do
      0 -> roman_upper(pos)
      1 -> alpha_upper(pos)
      2 -> Integer.to_string(pos + 1)
      3 -> alpha_lower(pos)
      4 -> roman_lower(pos)
    end
  end

  # --- Numeral helpers (pos is zero-based) -----------------------------------

  defp alpha_upper(pos), do: alpha(pos, ?A)
  defp alpha_lower(pos), do: alpha(pos, ?a)

  # Spreadsheet-style letters: A..Z, then AA, AB, ... so it never runs out.
  defp alpha(pos, base) do
    n = pos + 1

    Stream.unfold(n, fn
      0 -> nil
      m -> {rem(m - 1, 26), div(m - 1, 26)}
    end)
    |> Enum.map(&<<base + &1>>)
    |> Enum.reverse()
    |> Enum.join()
  end

  defp roman_upper(pos), do: roman(pos)
  defp roman_lower(pos), do: pos |> roman() |> String.downcase()

  @roman [
    {1000, "M"},
    {900, "CM"},
    {500, "D"},
    {400, "CD"},
    {100, "C"},
    {90, "XC"},
    {50, "L"},
    {40, "XL"},
    {10, "X"},
    {9, "IX"},
    {5, "V"},
    {4, "IV"},
    {1, "I"}
  ]

  defp roman(pos), do: to_roman(pos + 1, @roman, "")

  defp to_roman(0, _table, acc), do: acc
  defp to_roman(_n, [], acc), do: acc

  defp to_roman(n, [{value, sym} | rest], acc) when n >= value,
    do: to_roman(n - value, [{value, sym} | rest], acc <> sym)

  defp to_roman(n, [_ | rest], acc), do: to_roman(n, rest, acc)
end
