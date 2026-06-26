defmodule DoItWeb.Api.Serializer do
  @moduledoc """
  The canonical JSON shapes for the `/api/v1` **read surface** (m03.01 worklist
  2), and the pure functions that build them.

  Designed **MCP-first** (m03 design): an agent reads one of these shapes and can
  understand *and drive* the tree from it — every field an operation needs to
  target a task (its stable `id`, its `parent_id`, its sibling `position`) and
  every field that tells the agent what the tree currently *is* (the rolled-up
  `progress`, the `index` label, the `status`) is present in one response. The
  bar (north-star): driving a tree through this API is at least as efficient as
  editing the `docs/milestones/**` markdown hierarchy.

  Conventions (inherited from `DoItWeb.Api`): `snake_case` keys, ISO-8601 UTC
  timestamps, integer ids. All shapes are plain maps Jason renders directly.

  ## Initiative summary — `GET /api/v1/initiatives` list items

      {
        "id": 12,
        "name": "Q3 Launch",
        "subtitle": "ship the new dashboard",
        "role": "owner",
        "progress": 42
      }

  `role` is the acting user's role on the Initiative (`owner` | `editor` |
  `viewer`). `progress` is the Initiative's top-level rolled-up progress (its
  system root task's `computed_progress`, 0..100).

  ## Initiative tree — `GET /api/v1/initiatives/:id`

  The whole Initiative in one response: a small header plus the nested task tree.

      {
        "id": 12,
        "name": "Q3 Launch",
        "subtitle": "ship the new dashboard",
        "role": "owner",
        "progress": 42,
        "progress_calc": "leaf_average",
        "index_style": "numerical",
        "root_task_id": 100,
        "tasks": [ <task node>, ... ]
      }

  * `progress_calc` — how branch progress rolls up: `leaf_average` (every
    descendant leaf counts one unit) or `single_level` (each direct child one
    unit). The agent needs this to predict the effect of a progress write.
  * `index_style` — the positional index style the labels below are rendered in
    (`none` | `outline` | `numerical` | `roman` | `alphabetical`).
  * `root_task_id` — the id of the Initiative's system root task. It is **not** a
    node in `tasks` (the tree starts at its children), but it's the `parent_id`
    every top-level task carries — so to add a task at the top level (worklist 3),
    create it under `root_task_id`.
  * `tasks` — the top-level tasks (the children of the system root), each a
    **task node**.

  ## Task node (recursive)

      {
        "id": 101,
        "title": "Build the API",
        "index": "1.2",
        "position": 1,
        "parent_id": 100,
        "depth": 1,
        "progress": 50,
        "manual_progress": 50,
        "status": "in_progress",
        "done": false,
        "leaf": false,
        "priority": "high",
        "assignee_id": 7,
        "co_assignee_ids": [8, 9],
        "children": [ <task node>, ... ]
      }

  * `id` — the **stable** task id; the anchor every write op targets (it survives
    reorder/reparent).
  * `index` — the m02.07 §1.7 positional label for the Initiative's
    `index_style`. Derived purely from sibling position, so it's correct after
    any reorder. `""` under the `none` style.
  * `position` — the task's 0-based position among its siblings (the order is
    also implicit in array order). The slot a reorder/insert addresses.
  * `parent_id` — the parent task's id. A top-level task carries the Initiative's
    `root_task_id` (the system root — surfaced in the header, never a node here),
    not `null`.
  * `depth` — 0 for top-level, +1 per level — a convenience for rendering.
  * `progress` — the **rolled-up** progress (0..100): `computed_progress`, which
    the server maintains for every node (a leaf's equals its `manual_progress`,
    or 100 when `done`). This is the number the UI shows.
  * `manual_progress` — the raw leaf input (0..100). Settable directly only on a
    leaf; on a branch it's overridden by the roll-up.
  * `status` — `open` | `in_progress` | `done`. `done` is surfaced redundantly as
    the `done` boolean for convenience.
  * `leaf` — `true` when the task has no children (so `manual_progress` is its
    effective progress and is directly settable).
  * `assignee_id` — the primary assignee's user id, or `null`.
  * `co_assignee_ids` — the **complete** co-assignee user id list in promotion
    order (uncapped, unlike the UI's avatar chip).
  * `children` — nested task nodes (empty for a leaf).

  ## Activity event — `GET /api/v1/initiatives/:id/activity`

      {
        "id": 555,
        "kind": "progress_changed",
        "task_id": 101,
        "user_id": 7,
        "user_name": "Ada Lovelace",
        "data": {"from": 0, "to": 50},
        "inserted_at": "2026-06-26T21:16:46Z"
      }

  `kind` is the event verb (`created`, `title_changed`, `progress_changed`,
  `parent_changed`, `reordered`, `child_deleted`, `assignee_changed`,
  `commented`, `status_changed`, …); `data` carries that verb's from/to payload
  (the "review-as-diff" content). The activity endpoint wraps a list of these in
  `data` with a sibling `meta` pagination object — see
  `DoItWeb.Api.InitiativeController`.

  ## Member — `GET /api/v1/initiatives/:id/members`

      {
        "user_id": 7,
        "role": "owner",
        "name": "Ada Lovelace",
        "username": "ada",
        "email": "ada@example.com"
      }

  ## Comment — `GET /api/v1/initiatives/:id/tasks/:task_id/comments`

  A live comment:

      {
        "id": 33,
        "task_id": 101,
        "body": "looks good",
        "author_id": 7,
        "author_name": "Ada Lovelace",
        "deleted": false,
        "deleted_by_id": null,
        "deleted_at": null,
        "edited": true,
        "inserted_at": "2026-06-26T21:16:46Z",
        "updated_at": "2026-06-26T21:20:01Z"
      }

  A **tombstone** for a soft-deleted comment (per Q6 — surfaced, not omitted):

      {
        "id": 34,
        "task_id": 101,
        "body": null,
        "author_id": 8,
        "author_name": "Bob",
        "deleted": true,
        "deleted_by_id": 8,
        "deleted_at": "2026-06-26T22:00:00Z",
        "edited": false,
        "inserted_at": "2026-06-26T21:30:00Z",
        "updated_at": "2026-06-26T22:00:00Z"
      }

  A tombstone has `deleted: true` and its `body` nulled (the content is gone);
  the row stays so the thread shape and any references survive.
  """

  alias DoIt.Tasks
  alias DoIt.Tasks.{ActivityEvent, Comment, Task}

  @doc "An Initiative list item (`GET /api/v1/initiatives`)."
  def initiative_summary(initiative, role, progress) do
    %{
      id: initiative.id,
      name: initiative.name,
      subtitle: blank_to_empty(initiative.subtitle),
      role: role,
      progress: progress || 0
    }
  end

  @doc """
  The whole-Initiative tree response body (`GET /api/v1/initiatives/:id`).

  `tree` is the assembled task tree (`Tasks.initiative_task_tree/1`); `role` the
  acting user's role; `subtitle` / `progress` the Initiative header values;
  `co_ids` a `%{task_id => [user_id]}` map (`Tasks.co_assignee_ids_for_initiative/1`).
  """
  def initiative_tree(initiative, tree, role, subtitle, progress, co_ids) do
    %{
      id: initiative.id,
      name: initiative.name,
      subtitle: blank_to_empty(subtitle),
      role: role,
      progress: progress || 0,
      progress_calc: initiative.progress_calc,
      index_style: initiative.index_style,
      root_task_id: initiative.root_task_id,
      tasks: task_nodes(tree, initiative.index_style, co_ids, [], 0)
    }
  end

  # Serialize a sibling list into task nodes, threading each node's positional
  # index chain (`positions`) and depth down the tree so `index` and `depth`
  # come out right at every level.
  defp task_nodes(nodes, index_style, co_ids, parent_positions, depth) do
    nodes
    |> Enum.with_index()
    |> Enum.map(fn {%Task{} = task, position} ->
      positions = parent_positions ++ [position]

      %{
        id: task.id,
        title: task.title,
        index: DoIt.Tasks.Index.label(positions, index_style),
        position: position,
        parent_id: task.parent_id,
        depth: depth,
        progress: task.computed_progress,
        manual_progress: task.manual_progress,
        status: task.status,
        done: task.status == "done",
        leaf: task.children == [],
        priority: task.priority,
        assignee_id: task.assignee_id,
        co_assignee_ids: Map.get(co_ids, task.id, []),
        children: task_nodes(task.children, index_style, co_ids, positions, depth + 1)
      }
    end)
  end

  @doc "One activity event (`GET /api/v1/initiatives/:id/activity`)."
  def activity_event(%ActivityEvent{} = event) do
    %{
      id: event.id,
      kind: event.kind,
      task_id: event.task_id,
      user_id: event.user_id,
      user_name: user_name(event.user),
      data: event.data || %{},
      inserted_at: iso8601(event.inserted_at)
    }
  end

  @doc "One Initiative member with their role (`GET /api/v1/initiatives/:id/members`)."
  def member(membership) do
    user = membership.user

    %{
      user_id: membership.user_id,
      role: membership.role,
      name: user && user.name,
      username: user && user.username,
      email: user && user.email
    }
  end

  @doc "One comment, including the tombstone form for a soft-deleted comment."
  def comment(%Comment{} = comment) do
    deleted? = Tasks.comment_deleted?(comment)

    %{
      id: comment.id,
      task_id: comment.task_id,
      body: if(deleted?, do: nil, else: comment.body),
      author_id: comment.user_id,
      author_name: user_name(comment.user),
      deleted: deleted?,
      deleted_by_id: comment.deleted_by_id,
      deleted_at: iso8601(comment.deleted_at),
      edited: comment_edited?(comment),
      inserted_at: iso8601(comment.inserted_at),
      updated_at: iso8601(comment.updated_at)
    }
  end

  # `versions` is preloaded by Tasks.list_comments/1; any prior version means the
  # body was edited at least once.
  defp comment_edited?(%Comment{versions: versions}) when is_list(versions),
    do: versions != []

  defp comment_edited?(_), do: false

  defp user_name(%{name: name}), do: name
  defp user_name(_), do: nil

  # The blank subtitle is stored as the sentinel single space " " in the root
  # task's title (Initiatives.insert_root_task/3). Collapse any whitespace-only
  # value to "" so the list path matches the tree path's Initiatives.header/1
  # trim — a non-blank subtitle is passed through verbatim.
  # The blank subtitle is stored as the sentinel single space " " in the root
  # task's title (Initiatives.insert_root_task/3). Collapse any whitespace-only
  # value to "" so the list path matches the tree path's Initiatives.header/1
  # trim — a non-blank subtitle is passed through verbatim.
  defp blank_to_empty(nil), do: ""
  defp blank_to_empty(s) when is_binary(s) do
    if String.trim(s) == "", do: "", else: s
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso8601(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt) <> "Z"
end
