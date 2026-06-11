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

    # Single-root model: the sole `parent_id IS NULL` task is the Initiative's
    # system root; render its children as the top level (the root itself is not
    # a tree row). Fall back to the nil group if there's no root task yet.
    case Map.get(by_parent, nil, []) do
      [root] -> build_subtree(Map.get(by_parent, root.id, []), by_parent)
      roots -> build_subtree(roots, by_parent)
    end
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
  is assigned automatically, unless `attrs["position"]` gives a 0-based index
  among the siblings (item 18, form-slot placement). Records an `:created`
  activity event and recalculates ancestor progress. An auto-sorted parent is
  re-sorted afterward, overriding any requested position.
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
    position = normalize_position(Map.get(attrs, "position"))
    sort_order = next_sort_order(initiative_id, parent_id)

    attrs =
      attrs
      |> Map.delete("position")
      |> Map.put("created_by_id", actor.id)
      |> Map.put("updated_by_id", actor.id)
      |> Map.put_new("sort_order", sort_order)

    with {:ok, task} <- %Task{} |> Task.create_changeset(attrs) |> Repo.insert(),
         task <- maybe_set_done_progress(task) do
      # Item 18: place the new task in the form's slot when the caller gives a
      # position (manual parent); otherwise it stays appended. An auto-sorted
      # parent gets re-sorted by the caller (maybe_resort_children), overriding.
      task =
        if is_integer(position), do: insert_at_position(task, parent_id, position), else: task

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
      (or omitted) appends to the end, except a plain reparent into a
      different parent defaults to the top (index 0) per item 18.
    * `"reorder"` — truthy marks an explicit sibling/root reorder: pins the
      destination container to manual sort (item 16) and opts out of the
      reparent top default above.

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
    reorder? = reorder_flag(attrs)

    with_resort_batching(fn ->
      Repo.transaction(fn ->
        case move_task_body(task, actor, attrs) do
          {:ok, {moved, old_parent_id, new_parent_id}} ->
            # Item 16: an explicit sibling reorder pins the destination
            # container to manual so the placement survives the next
            # auto-resort. Must precede maybe_resort_children/1 below so that
            # resort sees the manual mode and becomes a no-op. A plain
            # reparent (append, no reorder flag) leaves the mode alone.
            if reorder?, do: pin_container_manual(new_parent_id, moved)

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

    old_parent_id = task.parent_id

    # Item 18: a plain reparent into a different parent with no explicit
    # position lands at the TOP of the new parent (position 0), not appended.
    # Reorder actions (sibling bands, root zones, Alt+↑/↓) carry their own
    # position — the root bottom-zone relies on nil meaning "append" — so the
    # top default is skipped for them. Auto-sorted parents get re-sorted by
    # the caller and override this default either way.
    position =
      case normalize_position(Map.get(attrs, "position")) do
        nil ->
          if new_parent_id != old_parent_id and not reorder_flag(attrs), do: 0, else: nil

        n ->
          n
      end

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

  Returns `{:ok, %{scenario: 1 | 2 | 3 | nil, titles: [String.t()], ids: [integer()]}}`
  or `{:error, reason}` where reason matches `move_task/3`. `titles` and `ids`
  describe the same flipped tasks, in the same order.

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

    # The dry-run rolled back — drop anything it queued for broadcast.
    discard_broadcasts(result)

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
          status != "done" and before_p != 100 and after_p == 100 -> [{:complete, title, id}]
          status == "done" and before_p == 100 and after_p != 100 -> [{:uncomplete, title, id}]
          true -> []
        end
      end)

    kinds = flips |> Enum.map(fn {kind, _, _} -> kind end) |> Enum.uniq()

    scenario =
      case kinds do
        [] -> nil
        [:uncomplete] -> 1
        [:complete] -> 2
        _ -> 3
      end

    %{
      scenario: scenario,
      titles: Enum.map(flips, fn {_, t, _} -> t end),
      ids: Enum.map(flips, fn {_, _, id} -> id end)
    }
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

  # Slot a just-created task at `index` among its parent's children,
  # renumbering the existing siblings into a fresh @sort_gap sequence (item
  # 18, form-slot placement). Mirrors perform_move/4's destination renumber.
  defp insert_at_position(%Task{} = task, parent_id, index) do
    siblings =
      from(t in Task,
        where: t.initiative_id == ^task.initiative_id and t.id != ^task.id,
        order_by: [asc: t.sort_order, asc: t.inserted_at]
      )
      |> with_parent(parent_id)
      |> Repo.all()

    insert_index = max(0, min(index, length(siblings)))
    new_sort_order = (insert_index + 1) * @sort_gap

    {:ok, placed} =
      task
      |> Ecto.Changeset.change(sort_order: new_sort_order)
      |> Repo.update()

    siblings
    |> Enum.with_index()
    |> Enum.each(fn {sibling, idx} ->
      new_order = if idx < insert_index, do: (idx + 1) * @sort_gap, else: (idx + 2) * @sort_gap
      if sibling.sort_order != new_order, do: persist_sort_order(sibling, new_order)
    end)

    placed
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

  defp reorder_flag(attrs) do
    Map.get(attrs, "reorder") in [true, "true"] or
      Map.get(attrs, :reorder) in [true, "true"]
  end

  # Item 16: quietly flip the destination container's sort_mode to "manual"
  # after an explicit reorder, so an auto-sort criterion doesn't immediately
  # undo the placement. A task parent flips the parent task; a root-level
  # reorder (nil parent) flips the Initiative. No activity event — the move's
  # own "reordered" event already records the user action; no updated_by bump,
  # mirroring persist_sort_order/2.
  # No container to pin: a parentless reorder has no sort field to set. With the
  # single-root model the container is always a task, so this is defensive.
  defp pin_container_manual(nil, _moved), do: :ok

  defp pin_container_manual(parent_id, _moved) when is_integer(parent_id) do
    parent = Repo.get!(Task, parent_id)

    if parent.sort_mode != "manual" do
      parent |> Ecto.Changeset.change(sort_mode: "manual") |> Repo.update!()
    end

    :ok
  end

  def delete_task(%Task{} = task, %User{} = actor) do
    with_resort_batching(fn ->
      Repo.transaction(fn ->
        parent_id = task.parent_id
        initiative_id = task.initiative_id
        title = task.title

        case Repo.delete(task) do
          {:ok, _deleted} ->
            # The "deleted" event lives on the PARENT's timeline — the task is
            # gone, and an activity row FK'd to it (task_id null: false,
            # on_delete: :delete_all) would fail to insert and roll the whole
            # delete back. Skip the event for a parentless task.
            if parent_id do
              case record_event_for(parent_id, initiative_id, actor, "child_deleted", %{
                     title: title
                   }) do
                {:ok, _} -> :ok
                {:error, cs} -> Repo.rollback(cs)
              end

              recompute_ancestors(parent_id)
            end

            broadcast_change(initiative_id, {:task_deleted, task.id})
            task

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

  # Reopening (done -> open / in_progress) drops the snapped 100 back to 0, so
  # progress reflects the reopen instead of staying stuck at 100. Symmetric with
  # the snap above, and covers the cascade path (branch uncheck), which only
  # flipped status and left descendants pinned at 100.
  defp maybe_set_done_progress(%Task{status: status} = updated, %Task{status: "done"})
       when status != "done" do
    updated
    |> Task.update_changeset(%{"manual_progress" => 0})
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
            # Reconcile the ancestor chain both ways, mirroring the leaf toggle:
            # marking a branch done may complete its now-fully-done parent;
            # reopening it may invalidate a done ancestor.
            if status == "open" do
              uncheck_done_ancestors(updated.parent_id, actor)
            else
              check_completed_ancestors(updated.parent_id, actor)
            end

            updated

          {:error, cs} ->
            Repo.rollback(cs)
        end
      end)
    end)
  end

  # One recursive CTE for the whole subtree — the per-node query loop this
  # replaces cost ~7ms per task and made big-branch operations feel sluggish.
  defp list_descendants(task_id) do
    initial = from(t in Task, where: t.parent_id == ^task_id)

    recursion =
      from(t in Task,
        inner_join: d in "descendants",
        on: t.parent_id == d.id
      )

    {"descendants", Task}
    |> recursive_ctes(true)
    |> with_cte("descendants", as: ^union_all(initial, ^recursion))
    |> Repo.all()
    # Loaded through the CTE, the structs' source is "descendants" — reset it
    # so later updates of these structs target the real table.
    |> Enum.map(&Ecto.put_meta(&1, source: Task.__schema__(:source)))
  end

  @doc "IDs of `task_id` and every task in the subtree below it."
  def subtree_ids(task_id) do
    [task_id | task_id |> list_descendants() |> Enum.map(& &1.id)]
  end

  @doc """
  The task plus its ancestors, preloaded for tree rendering — the set whose
  stored fields can change when the task is written (roll-ups walk up).
  One recursive query regardless of depth. Returns `[]` when the task no
  longer exists.
  """
  def lineage(task_id) do
    task_id
    |> ancestor_chain_query()
    |> Repo.all()
    |> Enum.map(&Ecto.put_meta(&1, source: Task.__schema__(:source)))
    |> Repo.preload([:assignee, :updated_by])
  end

  @doc "Child ids of `parent_id` in display order."
  def ordered_child_ids(parent_id) do
    Repo.all(
      from t in Task,
        where: t.parent_id == ^parent_id,
        order_by: [asc: t.sort_order, asc: t.inserted_at],
        select: t.id
    )
  end

  @doc "Display-ordered child ids for several parents, one query: %{parent_id => [ids]}."
  def ordered_child_ids_by_parent(parent_ids) do
    from(t in Task,
      where: t.parent_id in ^parent_ids,
      order_by: [asc: t.sort_order, asc: t.inserted_at],
      select: {t.parent_id, t.id}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @doc "IDs of every ancestor of `task_id` (unordered), root task included."
  def ancestor_ids(task_id) do
    task_id
    |> ancestor_chain_query()
    |> select([t], t.id)
    |> Repo.all()
    |> List.delete(task_id)
  end

  # The task + every ancestor as one recursive CTE (the per-level walk this
  # replaces cost ~5ms per depth level).
  defp ancestor_chain_query(task_id) do
    initial = from(t in Task, where: t.id == ^task_id)

    recursion =
      from(t in Task,
        inner_join: a in "ancestors",
        on: t.id == a.parent_id
      )

    {"ancestors", Task}
    |> recursive_ctes(true)
    |> with_cte("ancestors", as: ^union_all(initial, ^recursion))
  end

  @doc """
  Resolves the effective sort `{mode, reverse}` pair for a task's children.

  Walks the inheritance chain — the task's own `sort_mode`, up through
  parents to the root task, then the owning Initiative — and returns the
  `(mode, reverse)` pair from the first node with an explicit `sort_mode`.
  Falls back to `{"manual", false}` when every level is `nil`. Direction
  always travels with the mode that owns it, so a child cannot inherit
  the mode while overriding direction.

  Accepts a `%Task{}`, a task id, or `nil`. The walk terminates at the
  Initiative's root task (`parent_id IS NULL`) — sort lives only on tasks.
  """
  def resolve_sort(nil), do: {"manual", false}

  def resolve_sort(task_id) when is_integer(task_id) do
    case Repo.get(Task, task_id) do
      nil -> {"manual", false}
      %Task{} = task -> resolve_sort(task)
    end
  end

  def resolve_sort(%Task{sort_mode: mode, sort_reverse: rev}) when is_binary(mode),
    do: {mode, rev}

  # The root task: nothing above it, so an unset mode falls back to manual.
  def resolve_sort(%Task{parent_id: nil}), do: {"manual", false}

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
    |> flush_broadcasts()
  end

  @doc """
  Force every descendant branch of `root` to inherit (sort_mode `nil`), so
  the whole subtree follows `root`'s own setting from then on — a live link,
  not a stamped copy. Each descendant resorts by its resolved mode in the
  same transaction. Records ONE `sort_cascaded` activity event on the root
  (not per-descendant) and broadcasts once.

  Returns `{:ok, %{root_id: id, branch_count: n}}` or `{:error, ...}`.
  """
  def cascade_sort(%Task{} = root, %User{} = actor) do
    with_resort_batching(fn ->
      Repo.transaction(fn ->
        branches = descendant_branches(root.id)

        Enum.each(branches, fn t ->
          case set_sort_body(t, actor, nil, false) do
            {:ok, _} -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

        record_event(root, actor, "sort_cascaded", %{
          mode: "inherit",
          branch_count: length(branches)
        })

        # Multi-level reorder: the incremental patch re-keys one level only,
        # so collaborators need the structural (full reload) message.
        broadcast_change(root.initiative_id, {:task_moved, root.id})
        %{root_id: root.id, branch_count: length(branches)}
      end)
    end)
  end

  @doc "Count branch descendants of `task_id` (descendants that themselves have children)."
  def count_descendant_branches(task_id) when is_integer(task_id) do
    length(descendant_branches(task_id))
  end

  @doc "Count all descendant tasks of `task_id` (the whole subtree below it)."
  def count_descendants(task_id) when is_integer(task_id) do
    length(list_descendants(task_id))
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

      # Resort by the RESOLVED mode, so picking Inherit under e.g. an
      # Alphabetical ancestor re-orders the children immediately instead of
      # asserting an order the screen doesn't show (§8.11 finding). Explicit
      # modes resolve to themselves; manual (explicit or resolved) is a no-op.
      case resolve_sort(updated) do
        {"manual", _} -> :ok
        {mode, reverse} -> resort_children(updated.id, mode, reverse)
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
    result =
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

    # Every batching mutator's exit doubles as the post-commit broadcast
    # point (no-op when this was a nested call still inside a transaction).
    flush_broadcasts(result)
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
      order_by: [desc: e.inserted_at, desc: e.id],
      limit: ^limit,
      preload: [:user]
    )
    |> Repo.all()
  end

  defp record_event(%Task{} = task, %User{} = actor, kind, data) do
    record_event_for(task.id, task.initiative_id, actor, kind, data)
  end

  # Record against task/initiative ids directly — used when no live %Task{}
  # struct is on hand (e.g. logging a deletion on the surviving parent).
  defp record_event_for(task_id, initiative_id, %User{} = actor, kind, data) do
    %ActivityEvent{}
    |> ActivityEvent.changeset(%{
      task_id: task_id,
      initiative_id: initiative_id,
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
    reconcile_progress(initiative_id)
    initiative_task_tree(initiative_id)
  end

  defp persist_progress(%Task{} = task, value) do
    task
    |> Task.computed_progress_changeset(value)
    |> Repo.update!()
  end

  @doc """
  Reconcile computed_progress after a change at or under `task_id`'s parent.
  Leaf-average roll-up (ProductSpec § Roll-up Progress) can't be derived
  level-by-level from children's persisted percentages — it needs leaf
  masses too — so this recomputes the whole initiative's values from one
  query and writes only the diffs. Self-healing by construction.
  """
  def recompute_ancestors(nil), do: :ok

  def recompute_ancestors(task_id) when is_integer(task_id) do
    case Repo.get(Task, task_id) do
      nil -> :ok
      task -> reconcile_progress(task.initiative_id)
    end
  end

  defp recompute_self_and_ancestors(%Task{id: id} = task) do
    reconcile_progress(task.initiative_id)
    Repo.get!(Task, id)
  end

  defp reconcile_progress(initiative_id) do
    tasks = list_initiative_tasks(initiative_id)
    by_parent = Enum.group_by(tasks, & &1.parent_id)
    mode = progress_calc_mode(initiative_id)

    # Unlike assemble_tree/1, keep the system root as a node — the Initiative
    # header shows its roll-up.
    tree =
      case Map.get(by_parent, nil, []) do
        [root] ->
          [Map.put(root, :children, build_subtree(Map.get(by_parent, root.id, []), by_parent))]

        roots ->
          build_subtree(roots, by_parent)
      end

    values = Progress.compute_all(tree, mode)

    changed_parents =
      Enum.reduce(tasks, MapSet.new(), fn task, acc ->
        value = Map.get(values, task.id, task.computed_progress)

        if value != task.computed_progress do
          persist_progress(task, value)
          # A changed value re-sorts siblings under progress-keyed sort modes.
          if task.parent_id, do: MapSet.put(acc, task.parent_id), else: acc
        else
          acc
        end
      end)

    Enum.each(changed_parents, &maybe_resort_children/1)
    :ok
  end

  # The per-initiative calc setting (Initiative pane → Settings). Schemaless
  # read keeps Tasks from depending on the Initiatives schema.
  defp progress_calc_mode(initiative_id) do
    calc =
      Repo.one(
        from i in "initiatives",
          where: i.id == type(^initiative_id, :integer),
          select: i.progress_calc
      )

    if calc == "single_level", do: :single_level, else: :leaf_average
  end

  @doc """
  Broadcast a whole-tree change (multi-level reorder / recompute) so members
  full-reload rather than incrementally patch.
  """
  def notify_tree_changed(initiative_id, task_id),
    do: broadcast_change(initiative_id, {:task_moved, task_id})

  # --- PubSub ----------------------------------------------------------------

  def subscribe(initiative_id) do
    Phoenix.PubSub.subscribe(DoIt.PubSub, topic(initiative_id))
  end

  @pending_broadcasts :doit_pending_broadcasts

  # PubSub must fire AFTER commit. A broadcast sent mid-transaction reaches
  # subscribers while the writes are still invisible to their connections —
  # they reload the OLD state and stay stale forever. (The test sandbox
  # shares one connection, so tests cannot catch this; it only breaks against
  # real Postgres.) Inside a transaction the message queues in the process
  # dictionary; flush_broadcasts/1 sends the queue once the outermost
  # mutator's result is known.
  defp broadcast_change(initiative_id, message) do
    if Repo.in_transaction?() do
      Process.put(@pending_broadcasts, [
        {initiative_id, message} | Process.get(@pending_broadcasts, [])
      ])
    else
      Phoenix.PubSub.broadcast(DoIt.PubSub, topic(initiative_id), message)
    end

    :ok
  end

  # No-op while still inside a transaction (an outer mutator will flush).
  # Sends the queue on a successful result; drops it otherwise (rollback).
  defp flush_broadcasts(result) do
    cond do
      Repo.in_transaction?() ->
        result

      match?({:ok, _}, result) ->
        pending = Process.get(@pending_broadcasts, [])
        Process.delete(@pending_broadcasts)

        for {initiative_id, message} <- Enum.reverse(pending) do
          Phoenix.PubSub.broadcast(DoIt.PubSub, topic(initiative_id), message)
        end

        result

      true ->
        Process.delete(@pending_broadcasts)
        result
    end
  end

  defp discard_broadcasts(result) do
    Process.delete(@pending_broadcasts)
    result
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
