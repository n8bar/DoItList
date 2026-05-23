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
  alias DoIt.Initiatives.Initiative
  alias DoIt.Tasks.{ActivityEvent, Comment, Progress, Sort, Task}

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

    with_resort_batching(fn ->
      Repo.transaction(fn ->
        case create_task_body(actor, attrs) do
          {:ok, task} ->
            reconcile_after_create(task, actor)
            task = Repo.get!(Task, task.id)
            maybe_resort_children(task.parent_id)
            broadcast_change(task.initiative_id, {:task_created, task.id})
            task

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
    end)
  end

  # Body shared by `create_task` and `preview_create`. Does the insert + the
  # progress recompute, but NOT the status reconcile (which broadcasts).
  defp create_task_body(%User{} = actor, attrs) do
    initiative_id = attrs["initiative_id"]
    parent_id = attrs["parent_id"]
    sort_order = next_sort_order(initiative_id, parent_id)

    attrs =
      attrs
      |> Map.put("created_by_id", actor.id)
      |> Map.put("updated_by_id", actor.id)
      |> Map.put_new("sort_order", sort_order)

    with {:ok, task} <- %Task{} |> Task.create_changeset(attrs) |> Repo.insert(),
         task <- maybe_set_done_progress(task) do
      record_event(task, actor, "created", %{title: task.title})
      task = recompute_self_and_ancestors(task)
      {:ok, task}
    end
  end

  defp reconcile_after_create(%Task{parent_id: nil}, _actor), do: :ok

  defp reconcile_after_create(%Task{parent_id: parent_id, status: "done"}, actor),
    do: check_completed_ancestors(parent_id, actor)

  defp reconcile_after_create(%Task{parent_id: parent_id}, actor),
    do: uncheck_done_ancestors(parent_id, actor)

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

    with_resort_batching(fn ->
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

            # Auto-sorted parents need their children re-ordered when any
            # sort-key field on a child changes (status, priority, title,
            # progress). Dedup via with_resort_batching so the walk-up's
            # per-level fires don't repeat work for the same parent.
            maybe_resort_children(updated.parent_id)
            if old_parent && old_parent != new_parent, do: maybe_resort_children(old_parent)

            broadcast_change(updated.initiative_id, {:task_updated, updated.id})
            updated

          {:error, cs} ->
            Repo.rollback(cs)
        end
      end)
    end)
  end

  @sort_gap 1000

  @doc """
  Moves a task to a new parent and/or position within an Initiative.
  Cross-Initiative moves are not supported and return an error.

  `attrs` is a map (string or atom keys) with:
    * `"parent_id"` — the new parent's id, or `nil` for a root-level task.
      Defaults to the task's current `parent_id` if omitted.
    * `"position"` — 0-based insertion index among the new siblings. `nil`
      (or omitted) appends to the end.

  Runs in a single transaction:
    1. Validates the move (same Initiative, no cycle).
    2. Updates the moved task's `parent_id` + `sort_order`.
    3. Re-numbers siblings under the destination parent (and the source
       parent, when different) using a fixed gap so future single-row
       updates are cheap.
    4. Records a `parent_changed` and/or `reordered` activity event.
    5. Recomputes ancestor progress for both the OLD and NEW parent chains.
    6. Broadcasts `{:task_moved, id}` on the Initiative topic.

  Returns `{:ok, task}` or `{:error, reason}` where `reason` is one of
  `:cross_initiative`, `:cycle`, or an `Ecto.Changeset.t()`.
  """
  def move_task(%Task{} = task, %User{} = actor, attrs) do
    with_resort_batching(fn ->
      Repo.transaction(fn ->
        case move_task_body(task, actor, attrs) do
          {:ok, {moved, old_parent_id, new_parent_id}} ->
            reconcile_after_move(moved, old_parent_id, new_parent_id, actor)
            moved = Repo.get!(Task, moved.id)

            # Auto-sorted parents on both ends need to re-order their children.
            maybe_resort_children(new_parent_id)

            if old_parent_id && old_parent_id != new_parent_id,
              do: maybe_resort_children(old_parent_id)

            broadcast_change(moved.initiative_id, {:task_moved, moved.id})
            moved

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
    end)
  end

  # Body shared by `move_task` and `preview_move`. Does the structural move
  # and the computed_progress recompute, but NOT the status reconcile (which
  # broadcasts via update_task and so can't run inside a preview rollback).
  # Returns `{:ok, {moved, old_parent_id, new_parent_id}}` so the caller has
  # the context needed to reconcile or to compare before/after.
  defp move_task_body(%Task{} = task, %User{} = actor, attrs) do
    attrs = stringify_keys(attrs)

    new_parent_id =
      if Map.has_key?(attrs, "parent_id"),
        do: normalize_id(attrs["parent_id"]),
        else: task.parent_id

    position = normalize_position(Map.get(attrs, "position"))
    old_parent_id = task.parent_id

    with :ok <- validate_move(task, new_parent_id) do
      moved = perform_move(task, new_parent_id, position, actor)

      if old_parent_id != new_parent_id do
        record_event(moved, actor, "parent_changed", %{
          from: old_parent_id,
          to: new_parent_id
        })
      else
        record_event(moved, actor, "reordered", %{parent_id: new_parent_id})
      end

      if old_parent_id && old_parent_id != new_parent_id,
        do: recompute_ancestors(old_parent_id)

      if new_parent_id, do: recompute_ancestors(new_parent_id)

      {:ok, {Repo.get!(Task, moved.id), old_parent_id, new_parent_id}}
    end
  end

  # Auto-flip ancestor `status` to match the new child set, both chains.
  # Source chain may *gain* completeness (lost an incomplete child); destination
  # chain may *lose* it (gained an incomplete child).
  defp reconcile_after_move(moved, old_parent_id, new_parent_id, actor) do
    if old_parent_id && old_parent_id != new_parent_id,
      do: check_completed_ancestors(old_parent_id, actor)

    if new_parent_id do
      if moved.status == "done",
        do: check_completed_ancestors(new_parent_id, actor),
        else: uncheck_done_ancestors(new_parent_id, actor)
    end

    :ok
  end

  @doc """
  Dry-run a move. Runs `move_task_body` in a transaction, snapshots the
  ancestor chain progress before and after, rolls the transaction back, and
  classifies any completion-state flips it *would* cause.

  Returns `{:ok, %{scenario: 1 | 2 | 3 | nil, titles: [String.t()]}}` or
  `{:error, reason}` where reason matches `move_task/3`.

  Scenarios:
    1 — only previously-completed ancestors would become incomplete
    2 — only previously-incomplete ancestors would become completed
    3 — both directions happen in the same move
    nil — no completion-state changes
  """
  def preview_move(%Task{} = task, %User{} = actor, attrs) do
    attrs = stringify_keys(attrs)

    new_parent_id =
      if Map.has_key?(attrs, "parent_id"),
        do: normalize_id(attrs["parent_id"]),
        else: task.parent_id

    ancestor_ids =
      MapSet.union(
        ancestor_chain_ids(task.parent_id),
        ancestor_chain_ids(new_parent_id)
      )

    run_preview(ancestor_ids, fn -> move_task_body(task, actor, attrs) end)
  end

  @doc """
  Dry-run a create. Same shape as `preview_move/3`.
  """
  def preview_create(%User{} = actor, attrs) do
    attrs = stringify_keys(attrs)
    parent_id = normalize_id(attrs["parent_id"])
    ancestor_ids = ancestor_chain_ids(parent_id)

    run_preview(ancestor_ids, fn -> create_task_body(actor, attrs) end)
  end

  defp run_preview(ancestor_ids, body_fun) do
    result =
      Repo.transaction(fn ->
        before = snapshot_ancestors(ancestor_ids)

        case body_fun.() do
          {:ok, _} ->
            after_progress = snapshot_progress(ancestor_ids)
            Repo.rollback({:preview, before, after_progress})

          {:error, reason} ->
            Repo.rollback({:body_error, reason})
        end
      end)

    case result do
      {:error, {:preview, before, after_progress}} ->
        {:ok, classify_flips(before, after_progress)}

      {:error, {:body_error, reason}} ->
        {:error, reason}
    end
  end

  defp ancestor_chain_ids(nil), do: MapSet.new()

  defp ancestor_chain_ids(task_id) when is_integer(task_id) do
    case Repo.get(Task, task_id) do
      nil -> MapSet.new()
      %Task{parent_id: parent_id} -> MapSet.put(ancestor_chain_ids(parent_id), task_id)
    end
  end

  defp snapshot_ancestors(ancestor_ids) do
    ids = MapSet.to_list(ancestor_ids)

    from(t in Task,
      where: t.id in ^ids,
      select: %{id: t.id, status: t.status, progress: t.computed_progress, title: t.title}
    )
    |> Repo.all()
    |> Map.new(fn row -> {row.id, row} end)
  end

  defp snapshot_progress(ancestor_ids) do
    ids = MapSet.to_list(ancestor_ids)

    from(t in Task, where: t.id in ^ids, select: {t.id, t.computed_progress})
    |> Repo.all()
    |> Map.new()
  end

  # A flip is what the status helpers WOULD do once this move commits:
  #   was open + progress will be 100  → would auto-complete
  #   was done + progress will be < 100 → would auto-uncomplete
  # A flip requires a true crossing of the 100 threshold, not just an
  # end-state observation. A branch can legitimately sit at progress=100
  # with status="open" between leaf completion and the next status
  # reconcile pass — that pre-existing state must not be classified as
  # "would complete" by a no-op move.
  defp classify_flips(before, after_progress) do
    flips =
      Enum.flat_map(before, fn {id, %{status: status, progress: before_p, title: title}} ->
        after_p = Map.get(after_progress, id)

        cond do
          status != "done" and before_p != 100 and after_p == 100 -> [{:complete, title}]
          status == "done" and before_p == 100 and after_p != 100 -> [{:uncomplete, title}]
          true -> []
        end
      end)

    kinds = flips |> Enum.map(fn {kind, _} -> kind end) |> Enum.uniq()

    scenario =
      case kinds do
        [] -> nil
        [:uncomplete] -> 1
        [:complete] -> 2
        _ -> 3
      end

    %{scenario: scenario, titles: Enum.map(flips, fn {_, t} -> t end)}
  end

  defp validate_move(_task, nil), do: :ok

  defp validate_move(%Task{id: id}, new_parent_id) when new_parent_id == id,
    do: {:error, :cycle}

  defp validate_move(%Task{} = task, new_parent_id) do
    case Repo.get(Task, new_parent_id) do
      nil ->
        {:error, :cycle}

      %Task{initiative_id: pid_initiative} when pid_initiative != task.initiative_id ->
        {:error, :cross_initiative}

      _parent ->
        descendant_ids = task.id |> list_descendants() |> Enum.map(& &1.id) |> MapSet.new()

        if MapSet.member?(descendant_ids, new_parent_id),
          do: {:error, :cycle},
          else: :ok
    end
  end

  defp perform_move(%Task{} = task, new_parent_id, position, actor) do
    # Re-number existing siblings of the destination parent (excluding the moved
    # task) into a fresh sequence with @sort_gap spacing, then slot the moved
    # task in at `position` (or at the end when nil).
    siblings =
      from(t in Task,
        where: t.initiative_id == ^task.initiative_id and t.id != ^task.id,
        order_by: [asc: t.sort_order, asc: t.inserted_at]
      )
      |> with_parent(new_parent_id)
      |> Repo.all()

    insert_index =
      case position do
        nil -> length(siblings)
        n when n < 0 -> 0
        n -> min(n, length(siblings))
      end

    new_sort_order = (insert_index + 1) * @sort_gap

    {:ok, moved} =
      task
      |> Task.update_changeset(%{
        "parent_id" => new_parent_id,
        "sort_order" => new_sort_order,
        "updated_by_id" => actor.id
      })
      |> Repo.update()

    # Renumber destination siblings around the inserted position.
    siblings
    |> Enum.with_index()
    |> Enum.each(fn {sibling, idx} ->
      new_order = if idx < insert_index, do: (idx + 1) * @sort_gap, else: (idx + 2) * @sort_gap
      if sibling.sort_order != new_order, do: persist_sort_order(sibling, new_order)
    end)

    # If the source parent differs, also renumber the (now-reduced) source
    # siblings to keep their ordering tidy.
    if task.parent_id != new_parent_id do
      source_siblings =
        from(t in Task,
          where: t.initiative_id == ^task.initiative_id and t.id != ^task.id,
          order_by: [asc: t.sort_order, asc: t.inserted_at]
        )
        |> with_parent(task.parent_id)
        |> Repo.all()

      source_siblings
      |> Enum.with_index()
      |> Enum.each(fn {sibling, idx} ->
        new_order = (idx + 1) * @sort_gap
        if sibling.sort_order != new_order, do: persist_sort_order(sibling, new_order)
      end)
    end

    moved
  end

  defp with_parent(query, nil), do: from(t in query, where: is_nil(t.parent_id))
  defp with_parent(query, id), do: from(t in query, where: t.parent_id == ^id)

  defp persist_sort_order(%Task{} = task, value) do
    task
    |> Ecto.Changeset.change(sort_order: value)
    |> Repo.update!()
  end

  defp normalize_id(nil), do: nil
  defp normalize_id(""), do: nil
  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp normalize_position(nil), do: nil
  defp normalize_position(n) when is_integer(n), do: n

  defp normalize_position(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp normalize_position(_), do: nil

  def delete_task(%Task{} = task, %User{} = actor) do
    with_resort_batching(fn ->
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
  Toggle a task's done state. Both directions cascade up to keep the
  ProductSpec invariant intact — a parent can only be done if all
  descendants are:

  - done -> open: reopens the task and walks the ancestor chain,
    unchecking any ancestor that was done.
  - open -> done: marks the task done and walks the ancestor chain,
    auto-checking each ancestor whose entire child set is now done.
  """
  def toggle_complete(%Task{status: "done"} = task, %User{} = actor) do
    with_resort_batching(fn ->
      Repo.transaction(fn ->
        case update_task(task, actor, %{"status" => "open", "manual_progress" => 0}) do
          {:ok, updated} ->
            uncheck_done_ancestors(updated.parent_id, actor)
            updated

          {:error, cs} ->
            Repo.rollback(cs)
        end
      end)
    end)
  end

  def toggle_complete(%Task{} = task, %User{} = actor) do
    with_resort_batching(fn ->
      Repo.transaction(fn ->
        case update_task(task, actor, %{"status" => "done"}) do
          {:ok, updated} ->
            check_completed_ancestors(updated.parent_id, actor)
            updated

          {:error, cs} ->
            Repo.rollback(cs)
        end
      end)
    end)
  end

  defp check_completed_ancestors(nil, _actor), do: :ok

  defp check_completed_ancestors(parent_id, actor) do
    case Repo.get(Task, parent_id) do
      nil ->
        :ok

      parent ->
        siblings = Repo.all(from t in Task, where: t.parent_id == ^parent.id)
        all_done? = siblings != [] and Enum.all?(siblings, &(&1.status == "done"))

        if all_done? and parent.status != "done" do
          case update_task(parent, actor, %{"status" => "done"}) do
            {:ok, updated} -> check_completed_ancestors(updated.parent_id, actor)
            {:error, cs} -> Repo.rollback(cs)
          end
        else
          :ok
        end
    end
  end

  defp uncheck_done_ancestors(nil, _actor), do: :ok

  defp uncheck_done_ancestors(parent_id, actor) do
    case Repo.get(Task, parent_id) do
      nil ->
        :ok

      %Task{status: "done"} = parent ->
        case update_task(parent, actor, %{"status" => "open"}) do
          {:ok, updated} -> uncheck_done_ancestors(updated.parent_id, actor)
          {:error, cs} -> Repo.rollback(cs)
        end

      parent ->
        uncheck_done_ancestors(parent.parent_id, actor)
    end
  end

  @doc """
  Cascade a status change to a task and every descendant. Used for the
  parent-checkbox interaction: marking a parent done cascades down to all
  descendants; unchecking a parent cascades undone to all descendants and
  also walks up the ancestor chain (since unchecking might invalidate
  ancestors that were done). Wrapped in a single transaction.
  """
  def cascade_complete(%Task{} = task, %User{} = actor) do
    cascade_status(task, actor, "done")
  end

  def cascade_incomplete(%Task{} = task, %User{} = actor) do
    cascade_status(task, actor, "open")
  end

  defp cascade_status(%Task{} = task, %User{} = actor, status) do
    with_resort_batching(fn ->
      Repo.transaction(fn ->
        task.id
        |> list_descendants()
        |> Enum.each(fn descendant ->
          case update_task(descendant, actor, %{"status" => status}) do
            {:ok, _} -> :ok
            {:error, cs} -> Repo.rollback(cs)
          end
        end)

        case update_task(task, actor, %{"status" => status}) do
          {:ok, updated} ->
            if status == "open" do
              uncheck_done_ancestors(updated.parent_id, actor)
            end

            updated

          {:error, cs} ->
            Repo.rollback(cs)
        end
      end)
    end)
  end

  defp list_descendants(task_id) do
    immediate = Repo.all(from t in Task, where: t.parent_id == ^task_id)
    Enum.flat_map(immediate, fn t -> [t | list_descendants(t.id)] end)
  end

  @doc """
  Resolves the effective sort `{mode, reverse}` pair for a task's children.

  Walks the inheritance chain — the task's own `sort_mode`, up through
  parents to the root task, then the owning Initiative — and returns the
  `(mode, reverse)` pair from the first node with an explicit `sort_mode`.
  Falls back to `{"manual", false}` when every level is `nil`. Direction
  always travels with the mode that owns it, so a child cannot inherit
  the mode while overriding direction.

  Accepts a `%Task{}`, a task id, `nil`, or `{:initiative, id}`.
  """
  def resolve_sort(nil), do: {"manual", false}

  def resolve_sort({:initiative, initiative_id}) do
    case Repo.get(Initiative, initiative_id) do
      %Initiative{sort_mode: mode, sort_reverse: rev} when is_binary(mode) -> {mode, rev}
      _ -> {"manual", false}
    end
  end

  def resolve_sort(task_id) when is_integer(task_id) do
    case Repo.get(Task, task_id) do
      nil -> {"manual", false}
      %Task{} = task -> resolve_sort(task)
    end
  end

  def resolve_sort(%Task{sort_mode: mode, sort_reverse: rev}) when is_binary(mode),
    do: {mode, rev}

  def resolve_sort(%Task{parent_id: nil, initiative_id: initiative_id}),
    do: resolve_sort({:initiative, initiative_id})

  def resolve_sort(%Task{parent_id: parent_id}), do: resolve_sort(parent_id)

  @doc """
  Set the sort mode and direction on a branch task. When `mode` names an
  explicit non-manual criterion, re-sorts immediate children via
  `Tasks.Sort.apply/3` and persists the new `sort_order` values in the
  same transaction.

  `mode` may be `nil` (inherit), `"manual"`, or any value in
  `DoIt.Tasks.Task.sort_modes/0`. `reverse` is a boolean. `nil` and
  `"manual"` skip the re-sort — they only set the field. Logs a
  `sort_changed` activity event when either field changes.
  """
  def set_sort(%Task{} = task, %User{} = actor, mode, reverse) do
    Repo.transaction(fn ->
      case set_sort_body(task, actor, mode, reverse) do
        {:ok, updated} ->
          broadcast_change(updated.initiative_id, {:task_updated, updated.id})
          updated

        {:error, cs} ->
          Repo.rollback(cs)
      end
    end)
  end

  @doc """
  Set the same sort mode + direction on `root` and every branch
  descendant in a single transaction. Used by item 14's "Apply to all
  descendants" menu action. Records ONE `sort_cascaded` activity event
  on the root (not per-descendant) and broadcasts once.

  Returns `{:ok, %{root_id: id, branch_count: n}}` or `{:error, ...}`.
  """
  def cascade_sort(%Task{} = root, %User{} = actor, mode, reverse) do
    with_resort_batching(fn ->
      Repo.transaction(fn ->
        branches = [root | descendant_branches(root.id)]

        Enum.each(branches, fn t ->
          case set_sort_body(t, actor, mode, reverse) do
            {:ok, _} -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

        record_event(root, actor, "sort_cascaded", %{
          mode: mode,
          reverse: !!reverse,
          branch_count: length(branches)
        })

        broadcast_change(root.initiative_id, {:task_updated, root.id})
        %{root_id: root.id, branch_count: length(branches)}
      end)
    end)
  end

  @doc "Count branch descendants of `task_id` (descendants that themselves have children)."
  def count_descendant_branches(task_id) when is_integer(task_id) do
    length(descendant_branches(task_id))
  end

  # All descendants of `task_id` that are themselves parents (have children).
  # Returned as full task structs ordered by id for stable iteration.
  defp descendant_branches(task_id) do
    task_id
    |> list_descendants()
    |> Enum.filter(fn t ->
      Repo.exists?(from c in Task, where: c.parent_id == ^t.id)
    end)
  end

  # Shared body for `set_sort/4` and `cascade_sort/4`. Updates the field
  # pair, records a sort_changed event when either field changed, runs
  # the engine if mode is non-manual. Does NOT broadcast — callers
  # decide when to fan out.
  defp set_sort_body(%Task{} = task, %User{} = actor, mode, reverse) do
    changeset =
      Task.update_changeset(task, %{
        "sort_mode" => mode,
        "sort_reverse" => !!reverse,
        "updated_by_id" => actor.id
      })

    with {:ok, updated} <- Repo.update(changeset) do
      if task.sort_mode != updated.sort_mode or task.sort_reverse != updated.sort_reverse do
        record_event(updated, actor, "sort_changed", %{
          from: %{mode: task.sort_mode, reverse: task.sort_reverse},
          to: %{mode: updated.sort_mode, reverse: updated.sort_reverse}
        })
      end

      if is_binary(updated.sort_mode) and updated.sort_mode != "manual" do
        resort_children(updated.id, updated.sort_mode, updated.sort_reverse)
      end

      {:ok, updated}
    end
  end

  defp resort_children(parent_id, mode, reverse) do
    children = immediate_children(parent_id)
    sorted = Sort.apply(children, mode, reverse)
    new_orders = Map.new(sorted, fn c -> {c.id, c.sort_order} end)

    Enum.each(children, fn orig ->
      new_so = Map.fetch!(new_orders, orig.id)
      if orig.sort_order != new_so, do: persist_sort_order(orig, new_so)
    end)
  end

  # Resort a parent's immediate children if the resolved sort mode is
  # non-manual. Call after any mutation that changes a child's sort-key
  # (status, computed_progress, priority, title, etc.) so an auto-sorted
  # parent's children stay in order. No-op when the resolved mode is
  # "manual" or when `parent_id` is nil (root level).
  #
  # Within a `with_resort_batching/1` scope, repeat calls for the same
  # parent_id deduplicate — a deep recompute that fires this at every
  # ancestor level pays for each unique parent exactly once.
  defp maybe_resort_children(nil), do: :ok

  defp maybe_resort_children(parent_id) when is_integer(parent_id) do
    if mark_resorted(parent_id) == :already_resorted do
      :ok
    else
      case Repo.get(Task, parent_id) do
        nil ->
          :ok

        %Task{} = parent ->
          case resolve_sort(parent) do
            {"manual", _} -> :ok
            {mode, reverse} -> resort_children(parent.id, mode, reverse)
          end

          :ok
      end
    end
  end

  # Per-operation dedup scope for maybe_resort_children. Wraps a public
  # API entry point so a single user action (with its cascading recompute
  # walk-up) resorts each affected parent at most once.
  defp with_resort_batching(fun) do
    if Process.get(:resort_dedup) do
      fun.()
    else
      Process.put(:resort_dedup, MapSet.new())

      try do
        fun.()
      after
        Process.delete(:resort_dedup)
      end
    end
  end

  defp mark_resorted(parent_id) do
    case Process.get(:resort_dedup) do
      %MapSet{} = seen ->
        if MapSet.member?(seen, parent_id) do
          :already_resorted
        else
          Process.put(:resort_dedup, MapSet.put(seen, parent_id))
          :fresh
        end

      _ ->
        # No dedup scope — every call resorts.
        :fresh
    end
  end

  defp immediate_children(parent_id) do
    from(t in Task,
      where: t.parent_id == ^parent_id,
      order_by: [asc: t.sort_order, asc: t.inserted_at]
    )
    |> Repo.all()
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

        if progress != task.computed_progress do
          persist_progress(task, progress)
          # task's progress changed; if task.parent has an auto-sort mode
          # keyed on computed_progress, the siblings need to resort.
          maybe_resort_children(task.parent_id)
        end

        recompute_ancestors(task.parent_id)
    end
  end

  defp recompute_self_and_ancestors(%Task{id: id} = task) do
    task = preload_subtree(task)
    progress = Progress.compute_for_branch(task)

    if progress != task.computed_progress do
      persist_progress(task, progress)
      maybe_resort_children(task.parent_id)
    end

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
