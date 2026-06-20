defmodule DoIt.Tasks.Assigned do
  @moduledoc """
  The Assigned-to-Me read (m02.08 worklist 1 item 4): every live task where a
  user is the **primary** assignee or a **co-assignee**, scoped to Initiatives
  they're a **current member** of. Pure, cross-Initiative, flat — no tree.

  Tasks they've left / been removed from / trashed drop out via the
  current-member join. Completed tasks are hidden unless `:include_completed`.
  Tasks whose membership is archived or hidden are dropped unless
  `:include_archived_hidden`.

  Each returned row is an enriched `%Task{}` carrying virtual fields the
  Assigned-to-Me list renders:

    * `:assigned_as`     — `:primary` or `:co`
    * `:initiative_name` — the owning Initiative's name
    * `:progress_calc`   — that Initiative's badge mode (leaf_average / single_level)
    * `:child_count`     — direct children (single_level badge unit)
    * `:assigned_leaf_count` — subtree leaves (leaf_average badge unit)
    * `:from_archived_or_hidden` — true when surfaced only by a reveal toggle
  """

  import Ecto.Query

  alias DoIt.Repo
  alias DoIt.Accounts.User
  alias DoIt.Initiatives.{Initiative, InitiativeMember}
  alias DoIt.Tasks.{Task, TaskCoAssignee}

  @doc """
  Tasks assigned to `user` across all Initiatives they currently belong to.

  Options:
    * `:include_completed` (default `false`) — also show `status: "done"` tasks.
    * `:include_archived_hidden` (default `false`) — also show tasks from
      Initiatives the user has archived or hidden.

  Ordered by Initiative name, then task title, for a stable flat list (the
  caller groups by Initiative when the user opts in).
  """
  def list_assigned_to(%User{id: user_id}, opts \\ []) do
    include_completed? = Keyword.get(opts, :include_completed, false)
    include_archived_hidden? = Keyword.get(opts, :include_archived_hidden, false)

    # Each row pairs a task with how the user is on it ("primary"/"co") plus the
    # member row's archived/hidden state. The current-member join is what scopes
    # to live memberships: a left/removed/trashed Initiative has no member row,
    # so its tasks never appear. Primary and co come from a UNION so a user who
    # is both (impossible per exclusivity, but harmless) wouldn't duplicate.
    base =
      from(t in Task,
        join: i in Initiative,
        on: i.id == t.initiative_id and is_nil(i.trashed_at),
        join: m in InitiativeMember,
        on: m.initiative_id == t.initiative_id and m.user_id == ^user_id,
        where: is_nil(t.deleted_at)
      )

    primary =
      from([t, _i, m] in base,
        where: t.assignee_id == ^user_id,
        select: %{
          id: t.id,
          assigned_as: "primary",
          archived: not is_nil(m.archived_at),
          hidden: not is_nil(m.hidden_at)
        }
      )

    co =
      from([t, _i, m] in base,
        join: c in TaskCoAssignee,
        on: c.task_id == t.id and c.user_id == ^user_id,
        select: %{
          id: t.id,
          assigned_as: "co",
          archived: not is_nil(m.archived_at),
          hidden: not is_nil(m.hidden_at)
        }
      )

    rows = Repo.all(union(primary, ^co))

    case rows do
      [] ->
        []

      rows ->
        rows
        |> dedupe_primary_wins()
        |> filter_archived_hidden(include_archived_hidden?)
        |> enrich()
        |> filter_completed(include_completed?)
        |> sort_for_list()
    end
  end

  # A task can surface twice only if a user were both primary and co on it
  # (exclusivity forbids it, but be defensive): primary wins.
  defp dedupe_primary_wins(rows) do
    rows
    |> Enum.group_by(& &1.id)
    |> Enum.map(fn {_id, group} ->
      Enum.find(group, List.first(group), &(&1.assigned_as == "primary"))
    end)
  end

  defp filter_archived_hidden(rows, true), do: rows

  defp filter_archived_hidden(rows, false),
    do: Enum.reject(rows, &(&1.archived or &1.hidden))

  defp filter_completed(tasks, true), do: tasks
  defp filter_completed(tasks, false), do: Enum.reject(tasks, &(&1.status == "done"))

  # Load the real task structs + Initiative metadata + the two counts, then fold
  # the per-row relation/reveal flags back onto each.
  defp enrich(rows) do
    ids = Enum.map(rows, & &1.id)
    meta = Map.new(rows, &{&1.id, &1})

    child_counts = child_counts(ids)
    leaf_counts = leaf_counts(ids)

    from(t in Task,
      where: t.id in ^ids,
      join: i in Initiative,
      on: i.id == t.initiative_id,
      select: {t, i.name, i.progress_calc}
    )
    |> Repo.all()
    |> Enum.map(fn {task, initiative_name, progress_calc} ->
      m = Map.fetch!(meta, task.id)

      %{
        task
        | assigned_as: if(m.assigned_as == "primary", do: :primary, else: :co),
          initiative_name: initiative_name,
          progress_calc: progress_calc,
          child_count: Map.get(child_counts, task.id, 0),
          assigned_leaf_count: Map.get(leaf_counts, task.id, 1),
          from_archived_or_hidden: m.archived or m.hidden
      }
    end)
  end

  # Direct, live children per task in `ids` — the single_level badge unit.
  defp child_counts(ids) do
    from(t in Task,
      where: t.parent_id in ^ids and is_nil(t.deleted_at),
      group_by: t.parent_id,
      select: {t.parent_id, count(t.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  # Subtree leaf count per task in `ids` — the leaf_average badge unit. A
  # single recursive CTE tags every live descendant with the assigned-ancestor
  # it descends from; a task with no children counts as one leaf (itself).
  defp leaf_counts(ids) do
    # Seed: each assigned task is the root of its own subtree walk.
    seed =
      from(t in Task,
        where: t.id in ^ids and is_nil(t.deleted_at),
        select: %{root_id: t.id, id: t.id}
      )

    # Step: live children inherit their parent's root_id tag.
    step =
      from(t in Task,
        join: s in "subtree",
        on: t.parent_id == s.id,
        where: is_nil(t.deleted_at),
        select: %{root_id: s.root_id, id: t.id}
      )

    # A node is a leaf when no live child has it as parent. Count leaves per root.
    counts =
      from(s in "subtree",
        as: :node,
        where:
          not exists(
            from(c in Task,
              where: c.parent_id == parent_as(:node).id and is_nil(c.deleted_at)
            )
          ),
        group_by: s.root_id,
        select: {s.root_id, count(s.id)}
      )
      |> recursive_ctes(true)
      |> with_cte("subtree", as: ^union_all(seed, ^step))

    counts |> Repo.all() |> Map.new()
  end

  defp sort_for_list(tasks) do
    Enum.sort_by(tasks, fn t ->
      {String.downcase(t.initiative_name || ""), String.downcase(t.title || "")}
    end)
  end
end
