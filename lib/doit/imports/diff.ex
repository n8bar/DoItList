defmodule DoIt.Imports.Diff do
  @moduledoc """
  Pure import diffing (m03.04 item 2.5).

  A parsed manifest on one side, the live tree at an existing import target on
  the other; out comes a read-only report of how the two disagree. No Repo, no
  HTTP — the caller loads the tree, `from_tasks/1` flattens it to the shape
  below, and `compare/2` does the rest. **Nothing here writes.**

  ## Shapes

      compare(source_items, live_items) :: report

      source_item = %{title: String.t(), done: boolean, children: [source_item]}
      live_item   = %{title: String.t(), done: boolean, children: [live_item],
                      id: term}      # `id` optional; echoed in findings

      report = %{
        "clean" => boolean,
        "summary" => %{"matched" => n, "missing" => n, "extra" => n,
                       "completion" => n, "order" => n},
        "missing"    => [%{"path" => "A > B", "title" => "B"}],
        "extra"      => [%{"path" => ..., "title" => ..., "id" => id}],
        "completion" => [%{"path" => ..., "source_done" => bool,
                           "live_done" => bool, "id" => id}],
        "order"      => [%{"parent" => "(root)" | path,
                           "source" => [title], "live" => [title]}]
      }

  `clean` is true when every finding list is empty. Paths are the item's
  ancestry and its own title joined with `" > "`, counted from the compared
  level down; the top level's parent is named `"(root)"` in order entries.

  ## Matching

  Level by level — the top level, then the children of each matched pair.
  Titles match exactly after `String.trim/1` first; whatever is left over then
  matches case-insensitively. Among siblings sharing a title, the k-th source
  item pairs with the k-th live one, so duplicates line up in order rather than
  all collapsing onto the first.

  What falls out of the pairing:

    * an unmatched **source** item is `missing` (it isn't in the live tree);
    * an unmatched **live** item is `extra` (it isn't in the document);
    * a matched pair whose `done` differs is a `completion` mismatch;
    * a level whose matched items sit in a different relative order live than
      in the source is one `order` entry naming the parent and both orderings.

  Only matched pairs are recursed into. A missing or extra branch is reported
  once, as itself — its children are not enumerated, because the branch is the
  finding.
  """

  @root "(root)"
  @separator " > "

  @doc """
  Convert live `%DoIt.Tasks.Task{}` tree nodes (each with `:children`) into the
  `live_item` maps `compare/2` reads.
  """
  def from_tasks(tasks) when is_list(tasks), do: Enum.map(tasks, &from_task/1)

  defp from_task(task) do
    %{
      id: task.id,
      title: task.title,
      done: task.status == "done",
      children: from_tasks(children(task))
    }
  end

  @doc """
  Compare a manifest's items with the live items at the same level.

  Returns the report described in the moduledoc. Writes nothing, reads nothing
  outside its arguments.
  """
  def compare(source_items, live_items) when is_list(source_items) and is_list(live_items) do
    %{matched: 0, missing: [], extra: [], completion: [], order: []}
    |> walk(source_items, live_items, [], @root)
    |> report()
  end

  # --- Walk -------------------------------------------------------------------

  defp walk(acc, source_items, live_items, path, parent_label) do
    {pairs, unmatched_source, unmatched_live} = pair(source_items, live_items)

    acc
    |> Map.update!(:matched, &(&1 + length(pairs)))
    |> add_completion(pairs, path)
    |> add_missing(unmatched_source, path)
    |> add_extra(unmatched_live, path)
    |> add_order(pairs, parent_label)
    |> descend(pairs, path)
  end

  defp descend(acc, pairs, path) do
    Enum.reduce(pairs, acc, fn {{source, _si}, {live, _li}}, acc ->
      child_path = path ++ [source.title]
      walk(acc, children(source), children(live), child_path, join(child_path))
    end)
  end

  # --- Findings ---------------------------------------------------------------

  defp add_completion(acc, pairs, path) do
    Enum.reduce(pairs, acc, fn {{source, _si}, {live, _li}}, acc ->
      if done?(source) == done?(live) do
        acc
      else
        push(acc, :completion, %{
          "path" => join(path ++ [source.title]),
          "source_done" => done?(source),
          "live_done" => done?(live),
          "id" => id(live)
        })
      end
    end)
  end

  defp add_missing(acc, unmatched_source, path) do
    Enum.reduce(unmatched_source, acc, fn {source, _si}, acc ->
      push(acc, :missing, %{"path" => join(path ++ [source.title]), "title" => source.title})
    end)
  end

  defp add_extra(acc, unmatched_live, path) do
    Enum.reduce(unmatched_live, acc, fn {live, _li}, acc ->
      push(acc, :extra, %{
        "path" => join(path ++ [live.title]),
        "title" => live.title,
        "id" => id(live)
      })
    end)
  end

  # One entry per level, not per displaced item: the matched titles as the
  # source has them, and the same titles as the live tree has them.
  defp add_order(acc, pairs, parent_label) do
    live_positions = Enum.map(pairs, fn {{_s, _si}, {_l, li}} -> li end)

    if ascending?(live_positions) do
      acc
    else
      push(acc, :order, %{
        "parent" => parent_label,
        "source" => Enum.map(pairs, fn {{source, _si}, _live} -> source.title end),
        "live" =>
          pairs
          |> Enum.sort_by(fn {{_s, _si}, {_l, li}} -> li end)
          |> Enum.map(fn {{source, _si}, _live} -> source.title end)
      })
    end
  end

  defp ascending?(positions) do
    positions
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [a, b] -> a < b end)
  end

  # --- Pairing ----------------------------------------------------------------

  # Exact titles first, so a case-only near-match never steals a slot from a
  # literal one; the leftovers then pair case-insensitively.
  defp pair(source_items, live_items) do
    sources = Enum.with_index(source_items)
    lives = Enum.with_index(live_items)

    {exact, sources, lives} = match_by(sources, lives, &exact_key/1)
    {loose, sources, lives} = match_by(sources, lives, &loose_key/1)

    pairs = Enum.sort_by(exact ++ loose, fn {{_s, si}, _live} -> si end)
    {pairs, sources, lives}
  end

  defp match_by(sources, lives, key_fun) do
    buckets = Enum.group_by(lives, key_fun)

    {pairs, unmatched, buckets} =
      Enum.reduce(sources, {[], [], buckets}, fn source, {pairs, unmatched, buckets} ->
        key = key_fun.(source)

        case Map.get(buckets, key, []) do
          [live | rest] -> {[{source, live} | pairs], unmatched, Map.put(buckets, key, rest)}
          [] -> {pairs, [source | unmatched], buckets}
        end
      end)

    leftover_lives =
      buckets
      |> Enum.flat_map(fn {_key, lives} -> lives end)
      |> Enum.sort_by(fn {_live, li} -> li end)

    {Enum.reverse(pairs), Enum.reverse(unmatched), leftover_lives}
  end

  defp exact_key({item, _index}), do: String.trim(item.title)
  defp loose_key({item, _index}), do: item.title |> String.trim() |> String.downcase()

  # --- Report -----------------------------------------------------------------

  defp report(acc) do
    missing = Enum.reverse(acc.missing)
    extra = Enum.reverse(acc.extra)
    completion = Enum.reverse(acc.completion)
    order = Enum.reverse(acc.order)

    %{
      "clean" => missing == [] and extra == [] and completion == [] and order == [],
      "summary" => %{
        "matched" => acc.matched,
        "missing" => length(missing),
        "extra" => length(extra),
        "completion" => length(completion),
        "order" => length(order)
      },
      "missing" => missing,
      "extra" => extra,
      "completion" => completion,
      "order" => order
    }
  end

  # --- Item access ------------------------------------------------------------

  defp push(acc, key, entry), do: Map.update!(acc, key, &[entry | &1])

  defp join(path), do: Enum.join(path, @separator)

  # An unloaded association is no children, same as an absent key.
  defp children(item) do
    case Map.get(item, :children) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp done?(item), do: Map.get(item, :done) == true

  defp id(item), do: Map.get(item, :id)
end
