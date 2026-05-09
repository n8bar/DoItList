defmodule DoIt.Tasks do
  @moduledoc """
  Tasks, comments, activity log, and progress roll-up.

  ## Progress rules

  * A task with no children uses its `manual_progress` (0..100).
  * A task with children uses computed progress:

        sum(child_progress * child_weight) / sum(child_weight)

    where `child_progress` is itself the rolled-up value (recursive).
  * Marking a task `done` snaps progress to 100. Reopening (back to `open`
    or `in_progress`) lets manual progress drop below 100 again.
  * Changing a child's progress, weight, status, or parent triggers a
    recursive recalculation up the ancestor chain.
  """

  import Ecto.Query, warn: false

  alias DoIt.Repo
  alias DoIt.Accounts.User
  alias DoIt.Tasks.{ActivityEvent, Comment, Progress, Task}

  # --- Queries ---------------------------------------------------------------

  def get_task!(id), do: Repo.get!(Task, id)
  def get_task(id), do: Repo.get(Task, id)

  def get_task_with_relations(id) do
    Repo.one(
      from t in Task,
        where: t.id == ^id,
        preload: [:assignee, :created_by, :updated_by, :parent]
    )
  end

  @doc "All tasks for an Initiative, ordered for tree assembly."
  def list_initiative_tasks(initiative_id) do
    from(t in Task,
      where: t.initiative_id == ^initiative_id,
      order_by: [asc: t.sort_order, asc: t.inserted_at],
      preload: [:assignee, :updated_by]
    )
    |> Repo.all()
  end

  @doc """
  Builds a tree of tasks for an Initiative. Returns a list of root tasks (the
  separate Lists), each with a `:children` list, recursively.
  """
  def initiative_task_tree(initiative_id) do
    initiative_id
    |> list_initiative_tasks()
    |> assemble_tree()
  end

  defp assemble_tree(tasks) do
    by_parent = Enum.group_by(tasks, & &1.parent_id)
    build_subtree(Map.get(by_parent, nil, []), by_parent)
  end

  defp build_subtree(tasks, by_parent) do
    Enum.map(tasks, fn t ->
      children = build_subtree(Map.get(by_parent, t.id, []), by_parent)
      Map.put(t, :children, children)
    end)
  end

  # --- Create / Update / Delete ---------------------------------------------

  @doc """
  Creates a task. The next sort_order within the parent (or among root tasks)
  is assigned automatically. Records an `:created` activity event and
  recalculates ancestor progress.
  """
  def create_task(%User{} = actor, attrs) do
    attrs = stringify_keys(attrs)
    initiative_id = attrs["initiative_id"]
    parent_id = attrs["parent_id"]

    sort_order = next_sort_order(initiative_id, parent_id)

    attrs =
      attrs
      |> Map.put("created_by_id", actor.id)
      |> Map.put("updated_by_id", actor.id)
      |> Map.put_new("sort_order", sort_order)

    Repo.transaction(fn ->
      with {:ok, task} <- %Task{} |> Task.create_changeset(attrs) |> Repo.insert(),
           task <- maybe_set_done_progress(task) do
        record_event(task, actor, "created", %{title: task.title})
        task = recompute_self_and_ancestors(task)
        broadcast_change(task.initiative_id, {:task_created, task.id})
        task
      else
        {:error, cs} -> Repo.rollback(cs)
      end
    end)
  end

  @doc """
  Updates a task's editable fields. Records granular activity events for any
  meaningful field changes (title, status, progress, weight, assignee, parent).
  Triggers ancestor progress recalculation when needed.
  """
  def update_task(%Task{} = task, %User{} = actor, attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put("updated_by_id", actor.id)

    Repo.transaction(fn ->
      changeset = Task.update_changeset(task, attrs)

      case Repo.update(changeset) do
        {:ok, updated} ->
          updated = maybe_set_done_progress(updated, task)
          record_diff_events(task, updated, actor)

          # Re-compute progress for old and new parents (parent reparent)
          old_parent = task.parent_id
          new_parent = updated.parent_id

          if old_parent && old_parent != new_parent, do: recompute_ancestors(old_parent)
          if new_parent, do: recompute_ancestors(new_parent)

          # Always recompute self in case manual_progress changed
          updated = recompute_self_and_ancestors(updated)
          broadcast_change(updated.initiative_id, {:task_updated, updated.id})
          updated

        {:error, cs} ->
          Repo.rollback(cs)
      end
    end)
  end

  def delete_task(%Task{} = task, %User{} = actor) do
    Repo.transaction(fn ->
      parent_id = task.parent_id
      initiative_id = task.initiative_id

      case Repo.delete(task) do
        {:ok, deleted} ->
          record_event(deleted, actor, "deleted", %{title: deleted.title})
          if parent_id, do: recompute_ancestors(parent_id)
          broadcast_change(initiative_id, {:task_deleted, task.id})
          deleted

        {:error, cs} ->
          Repo.rollback(cs)
      end
    end)
  end

  defp maybe_set_done_progress(%Task{} = task), do: task

  defp maybe_set_done_progress(%Task{status: "done"} = updated, %Task{status: prev})
       when prev != "done" do
    updated
    |> Task.update_changeset(%{"manual_progress" => 100})
    |> Repo.update!()
  end

  defp maybe_set_done_progress(updated, _prev), do: updated

  @doc """
  Toggle a task's done state. Marking done snaps progress to 100 (via
  maybe_set_done_progress); reopening drops back to open + 0.
  """
  def toggle_complete(%Task{status: "done"} = task, %User{} = actor) do
    update_task(task, actor, %{"status" => "open", "manual_progress" => 0})
  end

  def toggle_complete(%Task{} = task, %User{} = actor) do
    update_task(task, actor, %{"status" => "done"})
  end

  @doc """
  Mark this task and every descendant as done. Uses `update_task/3` per node
  so each gets activity events and ancestor recompute. Wrapped in a single
  transaction so the cascade is atomic.
  """
  def cascade_complete(%Task{} = task, %User{} = actor) do
    Repo.transaction(fn ->
      task.id
      |> list_descendants()
      |> Enum.each(fn descendant ->
        case update_task(descendant, actor, %{"status" => "done"}) do
          {:ok, _} -> :ok
          {:error, cs} -> Repo.rollback(cs)
        end
      end)

      case update_task(task, actor, %{"status" => "done"}) do
        {:ok, updated} -> updated
        {:error, cs} -> Repo.rollback(cs)
      end
    end)
  end

  defp list_descendants(task_id) do
    immediate = Repo.all(from t in Task, where: t.parent_id == ^task_id)
    Enum.flat_map(immediate, fn t -> [t | list_descendants(t.id)] end)
  end

  defp next_sort_order(initiative_id, parent_id) do
    query =
      from t in Task,
        where: t.initiative_id == ^initiative_id,
        select: max(t.sort_order)

    query =
      case parent_id do
        nil -> from t in query, where: is_nil(t.parent_id)
        id -> from t in query, where: t.parent_id == ^id
      end

    case Repo.one(query) do
      nil -> 0
      n -> n + 1
    end
  end

  # --- Comments --------------------------------------------------------------

  def list_comments(task_id) do
    from(c in Comment,
      where: c.task_id == ^task_id,
      order_by: [asc: c.inserted_at],
      preload: [:user]
    )
    |> Repo.all()
  end

  def add_comment(%Task{} = task, %User{} = actor, body) do
    %Comment{}
    |> Comment.changeset(%{task_id: task.id, user_id: actor.id, body: body})
    |> Repo.insert()
    |> case do
      {:ok, comment} ->
        record_event(task, actor, "commented", %{comment_id: comment.id})
        broadcast_change(task.initiative_id, {:comment_added, task.id})
        {:ok, comment}

      err ->
        err
    end
  end

  # --- Activity --------------------------------------------------------------

  def list_task_activity(task_id, limit \\ 50) do
    from(e in ActivityEvent,
      where: e.task_id == ^task_id,
      order_by: [desc: e.inserted_at],
      limit: ^limit,
      preload: [:user]
    )
    |> Repo.all()
  end

  defp record_event(%Task{} = task, %User{} = actor, kind, data) do
    %ActivityEvent{}
    |> ActivityEvent.changeset(%{
      task_id: task.id,
      initiative_id: task.initiative_id,
      user_id: actor.id,
      kind: kind,
      data: data
    })
    |> Repo.insert()
  end

  defp record_diff_events(%Task{} = old, %Task{} = new, %User{} = actor) do
    [
      {:title, "title_changed"},
      {:manual_progress, "progress_changed"},
      {:weight, "weight_changed"},
      {:assignee_id, "assignee_changed"},
      {:parent_id, "parent_changed"},
      {:priority, "priority_changed"}
    ]
    |> Enum.each(fn {field, kind} ->
      old_v = Map.get(old, field)
      new_v = Map.get(new, field)

      if old_v != new_v and not (is_nil(old_v) and is_nil(new_v)) do
        record_event(new, actor, kind, %{
          from: jsonable(old_v),
          to: jsonable(new_v)
        })
      end
    end)
  end

  defp jsonable(%Decimal{} = d), do: Decimal.to_string(d)
  defp jsonable(other), do: other

  # --- Progress roll-up ------------------------------------------------------

  @doc """
  Recompute the rolled-up progress for the entire Initiative. Returns the
  updated tree.
  """
  def recompute_initiative_progress(initiative_id) do
    list_initiative_tasks(initiative_id)
    |> assemble_tree()
    |> Enum.each(&recompute_subtree/1)

    initiative_task_tree(initiative_id)
  end

  defp recompute_subtree(%Task{children: children} = task) when is_list(children) do
    Enum.each(children, &recompute_subtree/1)
    progress = Progress.compute_for_branch(Repo.preload(task, :children, force: true))
    if progress != task.computed_progress, do: persist_progress(task, progress)
    progress
  end

  defp recompute_subtree(%Task{} = task) do
    progress = Progress.compute(task)
    if progress != task.computed_progress, do: persist_progress(task, progress)
    progress
  end

  defp persist_progress(%Task{} = task, value) do
    task
    |> Task.computed_progress_changeset(value)
    |> Repo.update!()
  end

  @doc """
  Walk up from the given task, recomputing computed_progress for each
  ancestor. Stops at the root.
  """
  def recompute_ancestors(nil), do: :ok

  def recompute_ancestors(task_id) when is_integer(task_id) do
    case Repo.get(Task, task_id) do
      nil ->
        :ok

      task ->
        task = preload_subtree(task)
        progress = Progress.compute_for_branch(task)

        if progress != task.computed_progress, do: persist_progress(task, progress)

        recompute_ancestors(task.parent_id)
    end
  end

  defp recompute_self_and_ancestors(%Task{id: id} = task) do
    task = preload_subtree(task)
    progress = Progress.compute_for_branch(task)
    if progress != task.computed_progress, do: persist_progress(task, progress)
    recompute_ancestors(task.parent_id)
    Repo.get!(Task, id)
  end

  defp preload_subtree(%Task{} = task) do
    Repo.preload(task, [:children])
  end

  # --- PubSub ----------------------------------------------------------------

  def subscribe(initiative_id) do
    Phoenix.PubSub.subscribe(DoIt.PubSub, topic(initiative_id))
  end

  defp broadcast_change(initiative_id, message) do
    Phoenix.PubSub.broadcast(DoIt.PubSub, topic(initiative_id), message)
  end

  defp topic(initiative_id), do: "initiative:#{initiative_id}"

  # --- Helpers ---------------------------------------------------------------

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
