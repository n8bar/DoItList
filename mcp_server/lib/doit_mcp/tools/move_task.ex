defmodule DoitMcp.Tools.MoveTask do
  @moduledoc """
  Move one task, or many as one block, to a new parent and/or sibling position; reorder, reparent, promote, and demote are all this tool. Provide at least one of `parent_id`, `position`, or `reorder`; an empty move is rejected. Omitting `parent_id` keeps the current parent. Set `reorder: true` only for an explicit sibling reorder; it switches the destination to manual sorting. Omit it to append. `task_ids` moves many under `parent_id` (required) in the given order, one undo step; `reorder` and `expected_version` do not apply.

  Never loop this tool; batch multiple operations with `apply_operations`. Reply with `index` and `title`, never ids.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias DoitMcp.Tools.ExpectedVersion
  alias DoitMcp.{Client, ToolResult}

  @expected_version_doc ExpectedVersion.description()

  schema do
    field(:task_id, :integer, required: false)
    field(:task_ids, {:list, :integer}, required: false)
    field(:parent_id, :integer, required: false)
    field(:position, :integer, required: false)
    field(:reorder, :boolean, required: false)

    field(:expected_version, :integer,
      required: false,
      description: @expected_version_doc
    )
  end

  def execute(params, frame) do
    case operation(params) do
      {:ok, op} ->
        [op]
        |> Client.operations()
        |> then(&ToolResult.reply(frame, &1))

      {:error, message} ->
        {:reply, Response.error(Response.tool(), message), frame}
    end
  end

  # Exactly one of `task_id` / `task_ids` picks the shape (m04.02 2.1.3).
  defp operation(params) do
    case {Map.get(params, :task_id), Map.get(params, :task_ids)} do
      {nil, nil} ->
        {:error, "Pass task_id or task_ids."}

      {id, ids} when id != nil and ids != nil ->
        {:error, "Pass task_id or task_ids, not both."}

      {nil, []} ->
        {:error, "task_ids is empty."}

      {nil, ids} ->
        many(ids, params)

      {id, nil} ->
        {:ok,
         op(%{"id" => id}, data(params, [:parent_id, :position, :reorder, :expected_version]))}
    end
  end

  defp many(ids, params) do
    cond do
      Map.get(params, :parent_id) == nil ->
        {:error, "task_ids needs parent_id."}

      Map.get(params, :reorder) != nil ->
        {:error, "reorder does not apply to task_ids."}

      Map.get(params, :expected_version) != nil ->
        {:error, "expected_version does not apply to task_ids."}

      true ->
        {:ok, op(%{"ids" => ids}, data(params, [:parent_id, :position]))}
    end
  end

  defp op(target, data) do
    Map.merge(%{"op" => "update", "type" => "task", "data" => data}, target)
  end

  defp data(params, keys) do
    params
    |> Map.take(keys)
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end
end
