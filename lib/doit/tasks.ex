defmodule DoIt.Tasks do
  @moduledoc """
  Tasks, comments, activity log, and progress roll-up.

  ## Progress rules

  * A task with no children uses its `manual_progress` (0..100).
  * A task with children uses computed progress — the plain average over all
    descendant leaves (`DoIt.Tasks.Progress`; single-level average available
    as a per-initiative setting).
  * Marking a task `done` snaps progress to 100. Reopening (back to `open`
    or `in_progress`) lets manual progress drop below 100 again.
  * Changing a child's progress, status, or parent triggers a recursive
    recalculation up the ancestor chain.
  """

  import Ecto.Query, warn: false

  alias DoIt.Repo
  alias DoIt.Accounts.User
  alias DoIt.Tasks.{ActivityEvent, Comment, Progress, Sort, Task, TaskCoAssignee}

  # --- Queries ---------------------------------------------------------------

  def get_task!(id), do: Repo.get!(Task, id)
  def get_task(id), do: Repo.get(Task, id)

  def get_task_with_relations(id) do
    Repo.one(
      from t in Task,
        where: t.id == ^id,
        preload: [
          :assignee,
          :created_by,
          :updated_by,
          :parent,
          co_assignee_links:
            ^from(c in TaskCoAssignee, order_by: [asc: c.sort_order, asc: c.id], preload: [:user])
        ]
    )
  end

  @doc "All *live* tasks for an Initiative, ordered for tree assembly."
  def list_initiative_tasks(initiative_id) do
    from(t in Task,
      where: t.initiative_id == ^initiative_id and is_nil(t.deleted_at),
      order_by: [asc: t.sort_order, asc: t.inserted_at],
      preload: [:assignee, :updated_by]
    )
    |> Repo.all()
  end

  @doc """
  Tasks that `user_id` *leads* under Viewer+ (m02.05 item 12.6): every task
  where they are the direct (primary) assignee, plus all descendants — the
  subtree they may edit (progress / comments) and staff. A `MapSet` of task ids.
  The caller gates on the Initiative's `viewer_plus` flag and the user's role;
  this is just the assignment-derived reach (a recursive walk down from each
  led root).
  """
  def viewer_plus_led_ids(initiative_id, user_id) do
    roots =
      from(t in Task,
        where:
          t.initiative_id == ^initiative_id and t.assignee_id == ^user_id and
            is_nil(t.deleted_at),
        select: %{id: t.id}
      )

    descendants =
      from(t in Task,
        join: led in "led",
        on: t.parent_id == led.id,
        where: is_nil(t.deleted_at),
        select: %{id: t.id}
      )

    led_query = union(roots, ^descendants)

    from(l in "led", select: l.id)
    |> recursive_ctes(true)
    |> with_cte("led", as: ^led_query)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  The Viewer+ staffing pool for `viewer_id` acting on `task` (m02.05 item 12.6):
  the set of user ids they may set as `task`'s primary or co-assignees, drawn
  from the **nearest strict ancestor they directly lead** — the people they were
  handed there.

  Returns `nil` when the viewer may not staff `task` at all: either it's a task
  they directly lead (its own co-list is owner-seeded, off-limits) or no strict
  ancestor is theirs. A `MapSet` of user ids otherwise (possibly empty — a led
  task with no co-assignees hands down an empty pool).
  """
  def viewer_staff_pool(viewer_id, %Task{} = task) do
    if task.assignee_id == viewer_id do
      nil
    else
      case nearest_led_ancestor_id(viewer_id, task) do
        nil ->
          nil

        # The handed pool plus the viewer themselves — a viewer+ leads their
        # subtree, so they belong on its team and may add themselves as a
        # co-assignee (or primary) on a descendant, even though they aren't in
        # their own led ancestor's co-list.
        ancestor_id ->
          MapSet.put(co_assignee_ids(ancestor_id), viewer_id)
      end
    end
  end

  @doc """
  The nearest strict ancestor of `task` that `viewer_id` directly leads (m02.05
  item 12.6) — the task whose co-assignees form the staffing pool — or nil.
  Names the source in the viewer+ assign-denied toast.
  """
  def viewer_led_ancestor(viewer_id, %Task{} = task) do
    case nearest_led_ancestor_id(viewer_id, task) do
      nil -> nil
      id -> Repo.get(Task, id)
    end
  end

  # Walks `task`'s strict-ancestor chain from the parent up, returning the id of
  # the first ancestor the viewer is the direct assignee of — or nil. One query
  # loads the chain; the walk happens in memory (chains are shallow).
  defp nearest_led_ancestor_id(_viewer_id, %Task{parent_id: nil}), do: nil

  defp nearest_led_ancestor_id(viewer_id, %Task{} = task) do
    by_id =
      task.id
      |> ancestor_chain_query()
      |> select([t], {t.id, t.parent_id, t.assignee_id})
      |> Repo.all()
      |> Map.new(fn {id, parent_id, assignee_id} -> {id, {parent_id, assignee_id}} end)

    walk_to_led(by_id, task.parent_id, viewer_id)
  end

  defp walk_to_led(_by_id, nil, _viewer_id), do: nil

  defp walk_to_led(by_id, id, viewer_id) do
    case Map.get(by_id, id) do
      {_parent_id, ^viewer_id} -> id
      {parent_id, _assignee_id} -> walk_to_led(by_id, parent_id, viewer_id)
      nil -> nil
    end
  end

  defp co_assignee_ids(task_id) do
    from(c in TaskCoAssignee, where: c.task_id == ^task_id, select: c.user_id)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Builds a tree of tasks for an Initiative. Returns a list of root tasks (the
  separate Lists), each with a `:children` list, recursively.
  """
  # How many co-assignee avatars the row chip shows before overflowing to
  # "+N" (m02.05 item 12.4).
  @co_avatar_cap 8

  def initiative_task_tree(initiative_id) do
    initiative_id
    |> list_initiative_tasks()
    |> with_co_counts()
    |> assemble_tree()
  end

  # Attach each task's co-assignee count + a capped, ordered list of
  # co-assignee users (one query) for the overlapping-avatar chip (item 12.4)
  # — used on both the full tree load and the incremental lineage.
  defp with_co_counts(tasks) do
    ids = Enum.map(tasks, & &1.id)

    by_task =
      from(c in TaskCoAssignee,
        where: c.task_id in ^ids,
        order_by: [asc: c.sort_order, asc: c.id],
        preload: [:user]
      )
      |> Repo.all()
      |> Enum.group_by(& &1.task_id)

    Enum.map(tasks, fn t ->
      links = Map.get(by_task, t.id, [])

      %{
        t
        | co_assignee_count: length(links),
          co_assignee_users: links |> Enum.take(@co_avatar_cap) |> Enum.map(& &1.user)
      }
    end)
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
      |> apply_task_defaults(initiative_id, parent_id)

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

  # "My Task Defaults" (m02.04 §2.3) — always the *initiative owner's*
  # preferences, whoever creates the task, so an initiative behaves one way.
  # `put_new` throughout: explicit attrs from the caller win.
  defp apply_task_defaults(attrs, initiative_id, parent_id) do
    case Repo.get(DoIt.Initiatives.Initiative, initiative_id) do
      nil ->
        attrs

      initiative ->
        prefs = DoIt.Accounts.get_preferences_by_user_id(initiative.owner_id)

        attrs
        |> apply_default_sort(prefs)
        |> apply_default_priority(prefs, parent_id)
        |> apply_default_assignee(prefs, initiative)
    end
  end

  defp apply_default_sort(attrs, %{task_sort_mode: "match_parent"}), do: attrs

  defp apply_default_sort(attrs, %{task_sort_mode: mode}),
    do: Map.put_new(attrs, "sort_mode", mode)

  # "Match parent" copies the parent's priority; under the system root that's
  # "normal" by construction, which is the documented root-level fallback.
  defp apply_default_priority(attrs, %{task_priority: "match_parent"}, parent_id) do
    parent_priority =
      case parent_id && Repo.get(Task, parent_id) do
        %Task{priority: priority} -> priority
        _ -> "normal"
      end

    Map.put_new(attrs, "priority", parent_priority)
  end

  defp apply_default_priority(attrs, %{task_priority: priority}, _parent_id),
    do: Map.put_new(attrs, "priority", priority)

  defp apply_default_assignee(attrs, %{task_assign_owner: true}, initiative),
    do: Map.put_new(attrs, "assignee_id", initiative.owner_id)

  defp apply_default_assignee(attrs, _prefs, _initiative), do: attrs

  defp reconcile_after_create(%Task{parent_id: nil}, _actor), do: :ok

  defp reconcile_after_create(%Task{parent_id: parent_id, status: "done"}, actor),
    do: check_completed_ancestors(parent_id, actor)

  defp reconcile_after_create(%Task{parent_id: parent_id}, actor),
    do: uncheck_done_ancestors(parent_id, actor)

  @doc """
  Updates a task's editable fields. Records granular activity events for any
  meaningful field changes (title, status, progress, assignee, parent).
  Triggers ancestor progress recalculation when needed.
  """
  def update_task(%Task{} = task, %User{} = actor, attrs, opts \\ []) do
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
            # Completion (item 14) suppresses the per-task diff events and records
            # one atomic status_changed for the whole flip instead.
            if Keyword.get(opts, :record_events?, true),
              do: record_diff_events(task, updated, actor)

            # Exclusivity (m02.05 item 12.1): a user is either primary or
            # co-assignee, never both — promoting/assigning someone who's on
            # the co-list removes them from it.
            if updated.assignee_id && updated.assignee_id != task.assignee_id do
              drop_co_assignee(updated.id, updated.assignee_id)
            end

            # Auto-promote: an explicit clear of the primary backfills from the
            # co-list (first current member in manual order) when the
            # Initiative's setting is on.
            updated =
              if is_nil(updated.assignee_id) and not is_nil(task.assignee_id),
                do: maybe_auto_promote(updated, actor),
                else: updated

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
      # Capture the prior slot for undo (m02.06): old parent + index among its
      # live children, so the inverse puts the task back exactly where it was.
      old_index = old_parent_id |> ordered_child_ids() |> Enum.find_index(&(&1 == task.id))
      inverse = %{"parent_id" => old_parent_id, "position" => old_index}

      moved = perform_move(task, new_parent_id, position, actor)

      if old_parent_id != new_parent_id do
        record_event(
          moved,
          actor,
          "parent_changed",
          %{from: old_parent_id, to: new_parent_id, position: position},
          inverse
        )
      else
        record_event(
          moved,
          actor,
          "reordered",
          %{parent_id: new_parent_id, position: position},
          inverse
        )
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

      %Task{deleted_at: deleted_at} when not is_nil(deleted_at) ->
        {:error, :parent_deleted}

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
        where:
          t.initiative_id == ^task.initiative_id and t.id != ^task.id and is_nil(t.deleted_at),
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
          where:
            t.initiative_id == ^task.initiative_id and t.id != ^task.id and is_nil(t.deleted_at),
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
        where:
          t.initiative_id == ^task.initiative_id and t.id != ^task.id and is_nil(t.deleted_at),
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

  @doc """
  Soft-delete a task and its whole live subtree (m02.06): stamp `deleted_at` on
  every row so the id, comments, co-assignees, and descendants survive for undo
  / Trash. Records a `child_deleted` event on the parent carrying the deleted
  ids in `inverse_payload`, so the undo engine can restore exactly this set.
  """
  def delete_task(%Task{} = task, %User{} = actor) do
    with_resort_batching(fn ->
      Repo.transaction(fn ->
        parent_id = task.parent_id
        initiative_id = task.initiative_id
        title = task.title
        ids = subtree_ids(task.id)
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        {_n, _} =
          from(t in Task, where: t.id in ^ids)
          |> Repo.update_all(set: [deleted_at: now])

        # The "deleted" event lives on the PARENT's timeline (the task drops out
        # of the tree). Every real task has a parent in the single-root model;
        # only the system root is parentless and it isn't user-deletable.
        if parent_id do
          case record_event_for(
                 parent_id,
                 initiative_id,
                 actor,
                 "child_deleted",
                 %{title: title},
                 %{"deleted_ids" => ids, "task_id" => task.id}
               ) do
            {:ok, _} -> :ok
            {:error, cs} -> Repo.rollback(cs)
          end

          recompute_ancestors(parent_id)
        end

        broadcast_change(initiative_id, {:task_deleted, task.id})
        task
      end)
    end)
  end

  @doc """
  Restore a set of soft-deleted task ids (the undo of a `child_deleted`): clear
  `deleted_at`, recompute the ancestors' roll-ups, and broadcast a reload so the
  subtree reappears. Ids already live are left untouched.
  """
  def restore_tasks(ids, parent_id, initiative_id) when is_list(ids) do
    Repo.transaction(fn ->
      {_n, _} =
        from(t in Task, where: t.id in ^ids and not is_nil(t.deleted_at))
        |> Repo.update_all(set: [deleted_at: nil])

      if parent_id, do: recompute_ancestors(parent_id)
      broadcast_change(initiative_id, {:task_created, parent_id || List.first(ids)})
      :ok
    end)
  end

  # --- Undo / redo engine (m02.06 items 2/3) ---------------------------------

  # The mutations a v1 undo reverses. Completion is `status_changed` — one atomic
  # event per flip covering the whole cascade (item 14). The co-assignee set
  # events are still out of scope.
  @undoable_kinds ~w(parent_changed reordered child_deleted created title_changed description_changed progress_changed priority_changed assignee_changed commented status_changed)

  # Bounded depth (m02.06 items 6 + 11.4): only the most recent N undoable events
  # on an Initiative are reversible; older history drops off the shared stack.
  @undo_depth 500

  @doc """
  The next event `user` could undo on `initiative_id` — the Initiative's newest
  applied undoable event, by any member (m02.06 item 11), or nil. Gated on
  whether `user` may undo that op: owner/editor may undo any task op; a viewer+
  only ops within their privileges, so the first op they lack rights for walls
  them off (item 11.2); a plain viewer has nothing to undo.
  """
  def undo_candidate(%User{} = user, initiative_id) do
    role = DoIt.Initiatives.get_role(initiative_id, user.id)

    case newest_applied_event(initiative_id) do
      nil -> nil
      event -> if can_undo_event?(user, role, initiative_id, event), do: event, else: nil
    end
  end

  @doc """
  The next event `user` could redo on `initiative_id`, or nil. The Initiative's
  most-recently-undone event — but only while it's still the top: any newer
  *applied* action by *any* member invalidates the redo (item 11.3), and `user`
  must have rights to it.
  """
  def redo_candidate(%User{} = user, initiative_id) do
    candidate =
      from(e in ActivityEvent,
        where:
          e.initiative_id == ^initiative_id and e.kind in @undoable_kinds and
            not is_nil(e.undone_at),
        order_by: [desc: e.undone_at, desc: e.id],
        limit: 1
      )
      |> Repo.one()

    with %ActivityEvent{} = ev <- candidate,
         true <- still_top?(ev, initiative_id),
         role = DoIt.Initiatives.get_role(initiative_id, user.id),
         true <- can_undo_event?(user, role, initiative_id, ev) do
      ev
    else
      _ -> nil
    end
  end

  # The newest un-undone undoable event on the Initiative, within the depth
  # window — the shared top-of-stack (m02.06 item 11).
  defp newest_applied_event(initiative_id) do
    window =
      from(e in ActivityEvent,
        where: e.initiative_id == ^initiative_id and e.kind in @undoable_kinds,
        order_by: [desc: e.id],
        limit: @undo_depth,
        select: e.id
      )
      |> Repo.all()

    case window do
      [] ->
        nil

      ids ->
        from(e in ActivityEvent,
          where: e.id in ^ids and is_nil(e.undone_at),
          order_by: [desc: e.id],
          limit: 1
        )
        |> Repo.one()
    end
  end

  # A redo candidate is valid only while nothing applied is newer than it — a
  # fresh action branches the timeline and discards the redo for everyone.
  defp still_top?(%{id: id}, initiative_id) do
    max_done_id =
      from(e in ActivityEvent,
        where:
          e.initiative_id == ^initiative_id and e.kind in @undoable_kinds and
            is_nil(e.undone_at),
        select: max(e.id)
      )
      |> Repo.one()

    is_nil(max_done_id) or id > max_done_id
  end

  # Rights gate (m02.06 items 11.1/11.2): owner/editor may undo any task op; a
  # viewer+ only progress on a led task or an assignee change on a descendant
  # they may staff; a plain viewer (or non-member) nothing.
  defp can_undo_event?(_user, role, _initiative_id, _event) when role in ~w(owner editor),
    do: true

  defp can_undo_event?(%User{} = user, "viewer", initiative_id, event) do
    initiative = DoIt.Initiatives.get_initiative(initiative_id)

    initiative != nil and initiative.viewer_plus and
      viewer_plus_can_undo?(user.id, event, initiative_id)
  end

  defp can_undo_event?(_user, _role, _initiative_id, _event), do: false

  defp viewer_plus_can_undo?(user_id, %{kind: kind, task_id: task_id}, initiative_id)
       when kind in ~w(progress_changed commented status_changed) do
    MapSet.member?(viewer_plus_led_ids(initiative_id, user_id), task_id)
  end

  defp viewer_plus_can_undo?(
         user_id,
         %{kind: "assignee_changed", task_id: task_id},
         _initiative_id
       ) do
    case get_task(task_id) do
      nil -> false
      %Task{} = task -> viewer_staff_pool(user_id, task) != nil
    end
  end

  defp viewer_plus_can_undo?(_user_id, _event, _initiative_id), do: false

  @doc """
  Undo the Initiative's newest action `user` is entitled to reverse. Returns
  `{:ok, description}`, `{:error, :nothing_to_undo}`, or `{:error, {:conflict,
  description}}` when the target is gone (the dead entry is skipped so the user
  is never stuck). Broadcasts a reload like any mutation.
  """
  def undo(%User{} = user, initiative_id) do
    case undo_candidate(user, initiative_id) do
      nil -> {:error, :nothing_to_undo}
      event -> apply_reversal(event, user, :undo)
    end
  end

  @doc "Redo the Initiative's most-recently-undone event `user` is entitled to. See `undo/2`."
  def redo(%User{} = user, initiative_id) do
    case redo_candidate(user, initiative_id) do
      nil -> {:error, :nothing_to_redo}
      event -> apply_reversal(event, user, :redo)
    end
  end

  defp apply_reversal(event, user, direction) do
    outcome =
      Repo.transaction(fn ->
        case reverse(event, direction) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case outcome do
      {:ok, :ok} ->
        set_undone(event, if(direction == :undo, do: now_seconds(), else: nil))
        record_undo_meta(event, user, direction)
        broadcast_reversal(event, direction)
        {:ok, describe_event(event)}

      {:error, _reason} ->
        # Conflict (target deleted, parent gone…): step past the dead entry so
        # the stack never stalls (item 7).
        set_undone(event, if(direction == :undo, do: now_seconds(), else: nil))
        {:error, {:conflict, describe_event(event)}}
    end
  end

  # The PubSub message an undo/redo fans out (m02.06 item 14.4) — mirrors the
  # forward mutation for that kind so other viewers update incrementally
  # ({:task_updated} patches, {:task_moved} re-slots) instead of a blanket
  # {:task_created} that forced a full reload everywhere. Create / delete flip
  # by direction since the tree shape changes.
  defp reversal_broadcast(kind, _direction)
       when kind in ~w(title_changed description_changed progress_changed priority_changed assignee_changed),
       do: :task_updated

  defp reversal_broadcast(kind, _direction) when kind in ~w(parent_changed reordered),
    do: :task_moved

  defp reversal_broadcast("created", :undo), do: :task_deleted
  defp reversal_broadcast("created", :redo), do: :task_created
  defp reversal_broadcast("child_deleted", :undo), do: :task_created
  defp reversal_broadcast("child_deleted", :redo), do: :task_deleted
  # A comment change refreshes the task's comment list, not the tree.
  defp reversal_broadcast("commented", _direction), do: :comment_added
  defp reversal_broadcast(_kind, _direction), do: :task_created

  # Fan the reversal out like the forward mutation did. Completion (item 14)
  # mirrors the forward path's per-task broadcasts: one {:task_updated} for every
  # task the flip touched, so the up-cascade (ancestors, in the acted task's
  # lineage) and the down-cascade (descendants, which aren't) both patch
  # incrementally for everyone — cost proportional to the change, no full reload.
  defp broadcast_reversal(%{kind: "status_changed"} = event, _direction) do
    for %{"task_id" => id} <- event.inverse_payload["affected"] || [] do
      broadcast_change(event.initiative_id, {:task_updated, id})
    end

    :ok
  end

  defp broadcast_reversal(event, direction) do
    broadcast_change(
      event.initiative_id,
      {reversal_broadcast(event.kind, direction), event.task_id}
    )
  end

  # reverse/2 applies the state change. :undo runs the inverse; :redo re-runs the
  # forward action. Low-level (no new undoable events) — only the undid/redid
  # meta event is recorded, keeping the stack linear.
  defp reverse(%{kind: kind} = event, direction)
       when kind in ~w(parent_changed reordered) do
    target = if direction == :undo, do: event.inverse_payload, else: forward_move(event)

    case get_task(event.task_id) do
      nil ->
        {:error, :task_gone}

      %Task{} = task ->
        parent_id = normalize_id(target["parent_id"])

        with :ok <- validate_move(task, parent_id) do
          old_parent = task.parent_id
          perform_move(task, parent_id, target["position"], event_actor(event))
          if old_parent && old_parent != parent_id, do: recompute_ancestors(old_parent)
          recompute_ancestors(parent_id)
          :ok
        end
    end
  end

  defp reverse(%{kind: "child_deleted"} = event, direction) do
    ids = event.inverse_payload["deleted_ids"] || []
    parent_id = event.task_id

    {_n, _} =
      if direction == :undo do
        from(t in Task, where: t.id in ^ids) |> Repo.update_all(set: [deleted_at: nil])
      else
        from(t in Task, where: t.id in ^ids)
        |> Repo.update_all(set: [deleted_at: now_seconds()])
      end

    if parent_id, do: recompute_ancestors(parent_id)
    :ok
  end

  defp reverse(%{kind: "created"} = event, direction) do
    case get_task(event.task_id) do
      nil ->
        {:error, :task_gone}

      %Task{} = task ->
        ids = subtree_ids_any(task.id)

        {_n, _} =
          if direction == :undo do
            from(t in Task, where: t.id in ^ids)
            |> Repo.update_all(set: [deleted_at: now_seconds()])
          else
            from(t in Task, where: t.id in ^ids) |> Repo.update_all(set: [deleted_at: nil])
          end

        if task.parent_id, do: recompute_ancestors(task.parent_id)
        :ok
    end
  end

  # Attribute diffs (m02.06): the events already store from/to, so the inverse
  # is "set the field back". Progress feeds the roll-up; the rest are local.
  defp reverse(%{kind: kind} = event, direction)
       when kind in ~w(title_changed description_changed progress_changed priority_changed assignee_changed) do
    field = undo_field(kind)
    value = if direction == :undo, do: event.data["from"], else: event.data["to"]

    case get_task(event.task_id) do
      nil ->
        {:error, :task_gone}

      %Task{} = task ->
        task
        |> Ecto.Changeset.change(%{field => value})
        |> Repo.update()
        |> case do
          {:ok, updated} ->
            if kind == "progress_changed", do: recompute_ancestors(updated.parent_id)
            :ok

          {:error, _} ->
            {:error, :invalid}
        end
    end
  end

  # Comment add/remove (m02.06 item 14.5): undo soft-deletes the comment, redo
  # restores it — the comment id rides the event's data.
  defp reverse(%{kind: "commented"} = event, direction) do
    case event.data["comment_id"] do
      nil ->
        {:error, :comment_gone}

      comment_id ->
        if direction == :undo,
          do: soft_delete_comment(comment_id),
          else: restore_comment(comment_id)

        :ok
    end
  end

  # Completion (item 14): restore every task the flip touched to its prior (undo)
  # or next (redo) status + manual_progress in one atom — the acted task plus the
  # cascaded ancestors/descendants — then reconcile roll-ups. Tasks that vanished
  # since are skipped, never stalling the rest.
  defp reverse(%{kind: "status_changed"} = event, direction) do
    affected = event.inverse_payload["affected"] || []

    Enum.each(affected, fn a ->
      case get_task(a["task_id"]) do
        nil ->
          :ok

        %Task{} = task ->
          {status, progress} =
            if direction == :undo,
              do: {a["from_status"], a["from_progress"]},
              else: {a["to_status"], a["to_progress"]}

          task
          |> Ecto.Changeset.change(%{status: status, manual_progress: progress})
          |> Repo.update!()
      end
    end)

    reconcile_progress(event.initiative_id)
    :ok
  end

  defp undo_field("title_changed"), do: :title
  defp undo_field("description_changed"), do: :description
  defp undo_field("progress_changed"), do: :manual_progress
  defp undo_field("priority_changed"), do: :priority
  defp undo_field("assignee_changed"), do: :assignee_id

  # Redo of a move re-runs the forward landing (stored alongside from/to).
  defp forward_move(%{kind: "parent_changed", data: data}),
    do: %{"parent_id" => data["to"], "position" => data["position"]}

  defp forward_move(%{kind: "reordered", data: data}),
    do: %{"parent_id" => data["parent_id"], "position" => data["position"]}

  # Subtree ids regardless of deleted_at — used when re-deleting / restoring a
  # `created` task whose rows may already be soft-deleted.
  defp subtree_ids_any(task_id) do
    descendants =
      from(t in Task, inner_join: d in "tree", on: t.parent_id == d.id)

    initial = from(t in Task, where: t.id == ^task_id)

    [task_id] ++
      (from(t in "tree", select: t.id, where: t.id != ^task_id)
       |> recursive_ctes(true)
       |> with_cte("tree", as: ^union_all(initial, ^descendants))
       |> Repo.all())
  end

  defp set_undone(event, value) do
    event
    |> Ecto.Changeset.change(undone_at: value)
    |> Repo.update!()
  end

  defp now_seconds, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp event_actor(%{user_id: user_id}), do: Repo.get!(User, user_id)

  # The undid / redid feed entry (item 8) — labeled, never hiding the round-trip.
  defp record_undo_meta(event, user, direction) do
    kind = if direction == :undo, do: "undid", else: "redid"

    record_event_for(
      event.task_id,
      event.initiative_id,
      user,
      kind,
      %{"of" => describe_event(event)},
      nil
    )
  end

  @doc """
  A short human label for an undoable event — drives the toolbar tooltip and the
  undo/redo flash (m02.06 items 5/7).
  """
  def describe_event(%{kind: "parent_changed"}), do: "move"
  def describe_event(%{kind: "reordered"}), do: "reorder"
  def describe_event(%{kind: "child_deleted", data: data}), do: "delete \"#{data["title"]}\""
  def describe_event(%{kind: "created", data: data}), do: "create \"#{data["title"]}\""
  def describe_event(%{kind: "title_changed"}), do: "rename"
  def describe_event(%{kind: "description_changed"}), do: "description change"
  def describe_event(%{kind: "progress_changed"}), do: "progress change"
  def describe_event(%{kind: "priority_changed"}), do: "priority change"
  def describe_event(%{kind: "assignee_changed"}), do: "assignee change"
  def describe_event(%{kind: "commented"}), do: "comment"
  def describe_event(%{kind: "status_changed", data: %{"to" => "done"}}), do: "completion"
  def describe_event(%{kind: "status_changed"}), do: "reopen"
  def describe_event(_), do: "change"

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
        {updated, entry} = flip_status(task, actor, "open")
        ancestors = uncheck_done_ancestors(updated.parent_id, actor)
        record_status_event(task, actor, [entry | ancestors])
        updated
      end)
    end)
  end

  def toggle_complete(%Task{} = task, %User{} = actor) do
    with_resort_batching(fn ->
      Repo.transaction(fn ->
        {updated, entry} = flip_status(task, actor, "done")
        ancestors = check_completed_ancestors(updated.parent_id, actor)
        record_status_event(task, actor, [entry | ancestors])
        updated
      end)
    end)
  end

  # One status flip with **no** per-task event (item 14) — the atomic
  # status_changed the caller records subsumes it. Returns the updated task and
  # a {from,to}×{status,progress} entry for the undo payload.
  defp flip_status(%Task{} = task, %User{} = actor, status) do
    attrs =
      case status do
        "open" -> %{"status" => "open", "manual_progress" => 0}
        s -> %{"status" => s}
      end

    case update_task(task, actor, attrs, record_events?: false) do
      {:ok, updated} -> {updated, affected_entry(task, updated)}
      {:error, cs} -> Repo.rollback(cs)
    end
  end

  defp affected_entry(%Task{} = before, %Task{} = updated) do
    %{
      "task_id" => before.id,
      "from_status" => before.status,
      "from_progress" => before.manual_progress,
      "to_status" => updated.status,
      "to_progress" => updated.manual_progress
    }
  end

  # Record the whole completion as a single undoable status_changed event on the
  # task the user toggled (item 14). The inverse payload carries every task the
  # flip touched — the acted task, descendants flipped by a down-cascade, and
  # ancestors flipped by the up-cascade — each with its prior/next status +
  # manual_progress, so undo/redo reverses the whole cascade atomically. This is
  # what keeps one logical completion from fragmenting into per-ancestor
  # progress_changed events, one of which (on an out-of-domain root) would
  # otherwise wall a viewer+ off from undoing their own completion.
  defp record_status_event(%Task{} = acted, %User{} = actor, [acted_entry | _] = affected) do
    record_event(
      acted,
      actor,
      "status_changed",
      %{from: acted_entry["from_status"], to: acted_entry["to_status"]},
      %{"affected" => affected}
    )
  end

  defp check_completed_ancestors(nil, _actor), do: []

  defp check_completed_ancestors(parent_id, actor) do
    case Repo.get(Task, parent_id) do
      nil ->
        []

      parent ->
        siblings =
          Repo.all(from t in Task, where: t.parent_id == ^parent.id and is_nil(t.deleted_at))

        all_done? = siblings != [] and Enum.all?(siblings, &(&1.status == "done"))

        if all_done? and parent.status != "done" do
          {updated, entry} = flip_status(parent, actor, "done")
          [entry | check_completed_ancestors(updated.parent_id, actor)]
        else
          []
        end
    end
  end

  defp uncheck_done_ancestors(nil, _actor), do: []

  defp uncheck_done_ancestors(parent_id, actor) do
    case Repo.get(Task, parent_id) do
      nil ->
        []

      %Task{status: "done"} = parent ->
        {updated, entry} = flip_status(parent, actor, "open")
        [entry | uncheck_done_ancestors(updated.parent_id, actor)]

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
        descendant_entries =
          task.id
          |> list_descendants()
          |> Enum.map(fn descendant ->
            {_updated, entry} = flip_status(descendant, actor, status)
            entry
          end)

        {updated, acted_entry} = flip_status(task, actor, status)

        # Reconcile the ancestor chain both ways, mirroring the leaf toggle:
        # marking a branch done may complete its now-fully-done parent; reopening
        # it may invalidate a done ancestor.
        ancestor_entries =
          if status == "open" do
            uncheck_done_ancestors(updated.parent_id, actor)
          else
            check_completed_ancestors(updated.parent_id, actor)
          end

        # One atomic status_changed for the branch flip (item 14), acted task first.
        record_status_event(task, actor, [acted_entry | descendant_entries ++ ancestor_entries])
        updated
      end)
    end)
  end

  # One recursive CTE for the whole subtree — the per-node query loop this
  # replaces cost ~7ms per task and made big-branch operations feel sluggish.
  defp list_descendants(task_id) do
    initial = from(t in Task, where: t.parent_id == ^task_id and is_nil(t.deleted_at))

    recursion =
      from(t in Task,
        inner_join: d in "descendants",
        on: t.parent_id == d.id,
        where: is_nil(t.deleted_at)
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
    |> with_co_counts()
  end

  @doc "Live child ids of `parent_id` in display order."
  def ordered_child_ids(parent_id) do
    Repo.all(
      from t in Task,
        where: t.parent_id == ^parent_id and is_nil(t.deleted_at),
        order_by: [asc: t.sort_order, asc: t.inserted_at],
        select: t.id
    )
  end

  @doc "Display-ordered live child ids for several parents, one query: %{parent_id => [ids]}."
  def ordered_child_ids_by_parent(parent_ids) do
    from(t in Task,
      where: t.parent_id in ^parent_ids and is_nil(t.deleted_at),
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
      Repo.exists?(from c in Task, where: c.parent_id == ^t.id and is_nil(c.deleted_at))
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
      where: t.parent_id == ^parent_id and is_nil(t.deleted_at),
      order_by: [asc: t.sort_order, asc: t.inserted_at]
    )
    |> Repo.all()
  end

  defp next_sort_order(initiative_id, parent_id) do
    query =
      from t in Task,
        where: t.initiative_id == ^initiative_id and is_nil(t.deleted_at),
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
      where: c.task_id == ^task_id and is_nil(c.deleted_at),
      order_by: [asc: c.inserted_at],
      preload: [:user]
    )
    |> Repo.all()
  end

  # Soft-delete / restore a comment for the undo engine (m02.06 item 14.5).
  defp soft_delete_comment(comment_id) do
    from(c in Comment, where: c.id == ^comment_id)
    |> Repo.update_all(set: [deleted_at: now_seconds()])
  end

  defp restore_comment(comment_id) do
    from(c in Comment, where: c.id == ^comment_id)
    |> Repo.update_all(set: [deleted_at: nil])
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

  # --- Co-assignees (m02.05 item 12.1) --------------------------------------

  @doc "Ordered co-assignee links for a task, each with its `user` preloaded."
  def list_co_assignees(task_id) do
    from(c in TaskCoAssignee,
      where: c.task_id == ^task_id,
      order_by: [asc: c.sort_order, asc: c.id],
      preload: [:user]
    )
    |> Repo.all()
  end

  @doc """
  Append a co-assignee to the end of the task's list. Exclusivity: the
  current primary can't also be a co-assignee (no-op); an existing co-assignee
  is a no-op too.
  """
  def add_co_assignee(%Task{} = task, %User{} = actor, user_id) do
    cond do
      task.assignee_id == user_id ->
        {:error, :is_primary}

      Repo.get_by(TaskCoAssignee, task_id: task.id, user_id: user_id) ->
        {:error, :already_co}

      true ->
        Repo.transaction(fn ->
          next = next_co_sort_order(task.id)

          {:ok, link} =
            %TaskCoAssignee{}
            |> TaskCoAssignee.changeset(%{task_id: task.id, user_id: user_id, sort_order: next})
            |> Repo.insert()

          record_event(task, actor, "co_assignee_added", %{user_id: user_id})
          broadcast_change(task.initiative_id, {:task_updated, task.id})
          link
        end)
    end
  end

  @doc "Remove a co-assignee and compact the remaining order."
  def remove_co_assignee(%Task{} = task, %User{} = actor, user_id) do
    Repo.transaction(fn ->
      n = drop_co_assignee(task.id, user_id)
      if n > 0, do: record_event(task, actor, "co_assignee_removed", %{user_id: user_id})
      broadcast_change(task.initiative_id, {:task_updated, task.id})
      n
    end)
  end

  @doc """
  Set the manual co-assignee order from a full list of user ids (position =
  promotion order). Ids not currently on the list are ignored; missing ones
  keep their relative order after the supplied ones.
  """
  def reorder_co_assignees(%Task{} = task, %User{} = actor, ordered_user_ids) do
    Repo.transaction(fn ->
      links = list_co_assignees(task.id)
      by_user = Map.new(links, &{&1.user_id, &1})

      ordered =
        Enum.map(ordered_user_ids, &parse_int/1) |> Enum.filter(&Map.has_key?(by_user, &1))

      remainder = Enum.reject(Enum.map(links, & &1.user_id), &(&1 in ordered))

      (ordered ++ remainder)
      |> Enum.with_index()
      |> Enum.each(fn {user_id, idx} ->
        from(c in TaskCoAssignee, where: c.task_id == ^task.id and c.user_id == ^user_id)
        |> Repo.update_all(set: [sort_order: idx])
      end)

      record_event(task, actor, "co_assignees_reordered", %{order: ordered ++ remainder})
      broadcast_change(task.initiative_id, {:task_updated, task.id})
      :ok
    end)
  end

  @doc """
  Backfill the primary from the co-list when the Initiative's auto-promote
  setting is on: promote the first co-assignee in manual order who is a
  current member (non-members keep their place but are skipped). Returns the
  (possibly updated) task. Shared by the in-pane clear and member removal.
  """
  def maybe_auto_promote(%Task{} = task, %User{} = actor) do
    if auto_promote_on?(task.initiative_id) do
      promoted =
        task.id
        |> list_co_assignees()
        |> Enum.find(&current_member?(task.initiative_id, &1.user_id))

      case promoted do
        nil -> task
        link -> promote_co_to_primary(task, actor, link.user_id)
      end
    else
      task
    end
  end

  @doc "How many tasks in the Initiative the user is primary or co-assignee on."
  def member_assignment_count(initiative_id, user_id) do
    primary =
      Repo.aggregate(
        from(t in Task, where: t.initiative_id == ^initiative_id and t.assignee_id == ^user_id),
        :count
      )

    co =
      Repo.aggregate(
        from(c in TaskCoAssignee,
          join: t in Task,
          on: t.id == c.task_id,
          where: t.initiative_id == ^initiative_id and c.user_id == ^user_id
        ),
        :count
      )

    primary + co
  end

  @doc """
  Resolve a departing member's assignments (m02.05 item 12.1.5) so removal
  leaves no struck-through residue. For each task they're PRIMARY on:
  promote the next eligible co (when `promote_co` and one exists), else hand
  to `takeover_id`, else clear. Their CO-assignments are dropped. Runs in one
  transaction; each touched task broadcasts.
  """
  def handoff_member_assignments(initiative_id, %User{} = actor, leaving_user_id, opts \\ %{}) do
    # opts may be a map or keyword list — use Access on both.
    takeover_id = opts[:takeover_id]
    promote_co = opts[:promote_co] || false

    Repo.transaction(fn ->
      from(t in Task,
        where: t.initiative_id == ^initiative_id and t.assignee_id == ^leaving_user_id
      )
      |> Repo.all()
      |> Enum.each(&resolve_primary_handoff(&1, actor, leaving_user_id, takeover_id, promote_co))

      from(c in TaskCoAssignee,
        join: t in Task,
        on: t.id == c.task_id,
        where: t.initiative_id == ^initiative_id and c.user_id == ^leaving_user_id,
        select: c.task_id
      )
      |> Repo.all()
      |> Enum.each(fn task_id ->
        drop_co_assignee(task_id, leaving_user_id)
        broadcast_change(initiative_id, {:task_updated, task_id})
      end)

      :ok
    end)
  end

  defp resolve_primary_handoff(task, actor, leaving_id, takeover_id, promote_co) do
    co = if promote_co, do: first_handoff_co(task, leaving_id), else: nil
    new_assignee = co || takeover_id

    {:ok, _} =
      task
      |> Ecto.Changeset.change(assignee_id: new_assignee, updated_by_id: actor.id)
      |> Repo.update()

    # Exclusivity: the new primary leaves the co-list (covers a promoted co or
    # a takeover who happened to be a co-assignee).
    if new_assignee, do: drop_co_assignee(task.id, new_assignee)

    if co,
      do: record_event(task, actor, "co_assignee_promoted", %{user_id: co}),
      else: record_event(task, actor, "assignee_changed", %{from: leaving_id, to: new_assignee})

    broadcast_change(task.initiative_id, {:task_updated, task.id})
  end

  # First co-assignee in manual order who's a current member and not the
  # departing user.
  defp first_handoff_co(task, leaving_id) do
    case task.id
         |> list_co_assignees()
         |> Enum.find(
           &(&1.user_id != leaving_id and current_member?(task.initiative_id, &1.user_id))
         ) do
      nil -> nil
      link -> link.user_id
    end
  end

  defp auto_promote_on?(initiative_id) do
    Repo.one(
      from i in DoIt.Initiatives.Initiative,
        where: i.id == ^initiative_id,
        select: i.auto_promote_co_assignees
    ) || false
  end

  defp current_member?(initiative_id, user_id) do
    Repo.exists?(
      from m in DoIt.Initiatives.InitiativeMember,
        where: m.initiative_id == ^initiative_id and m.user_id == ^user_id
    )
  end

  defp promote_co_to_primary(%Task{} = task, %User{} = actor, user_id) do
    {:ok, updated} =
      task
      |> Ecto.Changeset.change(assignee_id: user_id, updated_by_id: actor.id)
      |> Repo.update()

    drop_co_assignee(task.id, user_id)
    record_event(task, actor, "co_assignee_promoted", %{user_id: user_id})
    updated
  end

  defp next_co_sort_order(task_id) do
    (Repo.one(from c in TaskCoAssignee, where: c.task_id == ^task_id, select: max(c.sort_order)) ||
       -1) + 1
  end

  # Delete a co-assignee link and compact the survivors' sort_order. Returns
  # the delete count. No broadcast/event — callers own those.
  defp drop_co_assignee(task_id, user_id) do
    {n, _} =
      from(c in TaskCoAssignee, where: c.task_id == ^task_id and c.user_id == ^user_id)
      |> Repo.delete_all()

    if n > 0, do: compact_co_order(task_id)
    n
  end

  defp compact_co_order(task_id) do
    from(c in TaskCoAssignee,
      where: c.task_id == ^task_id,
      order_by: [asc: c.sort_order, asc: c.id]
    )
    |> Repo.all()
    |> Enum.with_index()
    |> Enum.each(fn {link, idx} ->
      if link.sort_order != idx do
        link |> Ecto.Changeset.change(sort_order: idx) |> Repo.update()
      end
    end)
  end

  defp parse_int(n) when is_integer(n), do: n

  defp parse_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} -> i
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  defp record_event(%Task{} = task, %User{} = actor, kind, data, inverse \\ nil) do
    record_event_for(task.id, task.initiative_id, actor, kind, data, inverse)
  end

  # Record against task/initiative ids directly — used when no live %Task{}
  # struct is on hand (e.g. logging a deletion on the surviving parent).
  # `inverse` is the undo payload (m02.06), or nil.
  defp record_event_for(task_id, initiative_id, %User{} = actor, kind, data, inverse) do
    %ActivityEvent{}
    |> ActivityEvent.changeset(%{
      task_id: task_id,
      initiative_id: initiative_id,
      user_id: actor.id,
      kind: kind,
      data: data,
      inverse_payload: inverse
    })
    |> Repo.insert()
  end

  defp record_diff_events(%Task{} = old, %Task{} = new, %User{} = actor) do
    [
      {:title, "title_changed"},
      {:description, "description_changed"},
      {:manual_progress, "progress_changed"},
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
