defmodule DoIt.Tasks.Tree do
  @moduledoc """
  Pure helpers for surgically updating an in-memory task tree (the nested
  structure built by `DoIt.Tasks.initiative_task_tree/1`), so attribute-level
  changes patch the loaded tree instead of forcing a full reload + re-render.
  ProductSpec § Collaboration Model: propagation work scales with the size of
  the change, not the size of the tree.
  """

  @doc """
  Replace matching nodes' fields with freshly-loaded structs, keeping each
  node's existing `children`. Ids that don't appear in the tree are ignored.
  """
  def merge(tree, fresh_tasks) when is_list(fresh_tasks) do
    merge_nodes(tree, Map.new(fresh_tasks, &{&1.id, &1}))
  end

  defp merge_nodes(nodes, by_id) do
    Enum.map(nodes, fn node ->
      children = merge_nodes(node.children, by_id)

      by_id
      |> Map.get(node.id, node)
      |> Map.put(:children, children)
    end)
  end

  @doc """
  Re-key the order of `parent_id`'s children (`:root` = the top-level list) to
  `ordered_ids`, keeping each child's subtree. Children missing from
  `ordered_ids` keep their relative order at the end; the tree is returned
  unchanged when the parent isn't present.
  """
  def reorder_children(tree, :root, ordered_ids), do: sort_by_ids(tree, ordered_ids)

  def reorder_children(tree, parent_id, ordered_ids) do
    Enum.map(tree, fn node ->
      children =
        if node.id == parent_id,
          do: sort_by_ids(node.children, ordered_ids),
          else: reorder_children(node.children, parent_id, ordered_ids)

      Map.put(node, :children, children)
    end)
  end

  defp sort_by_ids(nodes, ordered_ids) do
    index = ordered_ids |> Enum.with_index() |> Map.new()
    fallback = map_size(index)

    nodes
    |> Enum.with_index()
    |> Enum.sort_by(fn {node, i} -> {Map.get(index, node.id, fallback), i} end)
    |> Enum.map(&elem(&1, 0))
  end
end
