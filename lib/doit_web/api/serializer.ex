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
        "url": "https://doitlist.app/initiatives/12",
        "role": "owner",
        "progress": 42,
        "root_task_id": 100
      }

  `url` is the Initiative's web address — the operator-facing handle (m03.04
  item 2.14): when telling a human about an Initiative, hand them the URL or
  the name, never a raw id. Composed server-side from the endpoint's public
  URL config, so a future id-scheme change costs the reader nothing. `role` is
  the acting user's role on the Initiative (`owner` | `editor` |
  `viewer`). `progress` is the Initiative's top-level rolled-up progress (its
  system root task's `computed_progress`, 0..100). `root_task_id` is the
  Initiative's system root task — the Initiative's own comment thread lives on
  it (item 6.4): read/write comments with `task_id = root_task_id`.

  ## Initiative tree — `GET /api/v1/initiatives/:id`

  The whole Initiative in one response: a small header plus the nested task tree.

      {
        "id": 12,
        "name": "Q3 Launch",
        "subtitle": "ship the new dashboard",
        "url": "https://doitlist.app/initiatives/12",
        "role": "owner",
        "progress": 42,
        "progress_calc": "leaf_average",
        "index_style": "numerical",
        "root_task_id": 100,
        "tasks": [ <task node>, ... ]
      }

  * `url` — the Initiative's web address, the operator-facing handle (same as
    on the list summary above).
  * `progress_calc` — how branch progress rolls up: `leaf_average` (every
    descendant leaf counts one unit) or `single_level` (each direct child one
    unit). The agent needs this to predict the effect of a progress write.
  * `index_style` — the positional index style the labels below are rendered in
    (`none` | `outline` | `numerical` | `roman` | `alphabetical`).
  * `root_task_id` — the id of the Initiative's system root task. It is **not** a
    node in `tasks` (the tree starts at its children), but it's the `parent_id`
    every top-level task carries — so to add a task at the top level (worklist 3),
    create it under `root_task_id`. The Initiative's own comment thread also
    lives on it (item 6.4): read/write comments with `task_id = root_task_id`.
  * `tasks` — the top-level tasks (the children of the system root), each a
    **task node**.

  ## Task node (recursive)

      {
        "id": 101,
        "title": "Build the API",
        "description": "how: wrap the context in a controller",
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
        "comment_count": 2,
        "cross_references": [
          {"target_id": 205, "target_index": "2.1", "target_title": "Ship the SDK"}
        ],
        "referenced_by": [
          {"source_id": 140, "source_index": "1.3", "source_title": "Plan the launch"}
        ],
        "children": [ <task node>, ... ]
      }

  * `id` — the **stable** task id; the anchor every write op targets (it survives
    reorder/reparent).
  * `description` — the task's how-to text, verbatim (`null` when unset). The
    read-back of the `description` the write ops accept; the `ingest_report`
    lint facts (m03.04 item 3.5) are computed over it adapter-side.
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
  * `comment_count` — how many **live** comments the task has (tombstones
    excluded). A dumb count (m03.04 item 3.5.2): the reader decides what a zero
    means; batched in one grouped query (no N+1).
  * `cross_references` — this task's **outgoing** task→task references (worklist
    4). Each entry carries the target's stable `target_id` and its **live**
    `target_index` label (computed from the current tree, so it never rots on a
    reorder/reparent) plus `target_title`. Anchored on the stable id; the link
    survives any reorder. Same-Initiative only, so the target is always in this
    tree. A reference whose endpoint is soft-deleted (Trashed) is **hidden** until
    restore. `[]` when the task references nothing.
  * `referenced_by` — the **incoming** side: tasks (in this Initiative) that
    cross-reference this one, each with the `source_id` / `source_index` /
    `source_title`. `[]` when nothing points here. Same single link query feeds
    both directions (no extra round-trip).
  * `children` — nested task nodes (empty for a leaf).

  ## Task ref — `GET /api/v1/tasks/:id`

      {
        "id": 101,
        "initiative_id": 12
      }

  The task → Initiative resolver (m03.04 item 2.18.1) — deliberately minimal:
  just enough for a caller holding a bare task id (e.g. a `parent_id`) to
  learn which Initiative it belongs to. The full task shape lives in the
  Initiative tree read above.

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

  use DoItWeb, :verified_routes

  alias DoIt.Tasks
  alias DoIt.Tasks.{ActivityEvent, Comment, Task}

  @doc "An Initiative list item (`GET /api/v1/initiatives`)."
  def initiative_summary(initiative, role, progress) do
    %{
      id: initiative.id,
      name: initiative.name,
      subtitle: blank_to_empty(initiative.subtitle),
      url: initiative_url(initiative.id),
      role: role,
      progress: progress || 0,
      root_task_id: initiative.root_task_id
    }
  end

  @doc """
  The whole-Initiative tree response body (`GET /api/v1/initiatives/:id`).

  `tree` is the assembled task tree (`Tasks.initiative_task_tree/1`); `role` the
  acting user's role; `subtitle` / `progress` the Initiative header values;
  `co_ids` a `%{task_id => [user_id]}` map (`Tasks.co_assignee_ids_for_initiative/1`);
  `comment_counts` a `%{task_id => count}` map
  (`Tasks.comment_counts_for_initiative/1`); `links` the live cross-references
  as `[{source_id, target_id}]` (`Tasks.list_links_for_initiative/1`).

  The cross-references' target labels are computed from a single pre-pass over
  the same tree (`label_index`), so resolving every reference to its **live**
  index label adds **no** query (batched, no N+1).
  """
  def initiative_tree(initiative, tree, role, subtitle, progress, co_ids, comment_counts, links) do
    index_style = initiative.index_style

    ctx = %{
      index_style: index_style,
      co_ids: co_ids,
      comment_counts: comment_counts,
      label_index: DoIt.Tasks.label_index(tree, index_style),
      outgoing: adjacency(links, :outgoing),
      incoming: adjacency(links, :incoming)
    }

    %{
      id: initiative.id,
      name: initiative.name,
      subtitle: blank_to_empty(subtitle),
      url: initiative_url(initiative.id),
      role: role,
      progress: progress || 0,
      progress_calc: initiative.progress_calc,
      index_style: index_style,
      # AI-KNOBS-PARKED (m03.04): not serialized to agents pending the skill
      # rebuild; column retained. Revive this line.
      # ai_knobs: initiative.ai_knobs,
      root_task_id: initiative.root_task_id,
      tasks: task_nodes(tree, ctx, [], 0)
    }
  end

  # Serialize a sibling list into task nodes, threading each node's positional
  # index chain (`positions`) and depth down the tree so `index` and `depth`
  # come out right at every level. `ctx` carries the index style, co-assignee
  # map, the precomputed label index, and the link adjacency maps.
  defp task_nodes(nodes, ctx, parent_positions, depth) do
    nodes
    |> Enum.with_index()
    |> Enum.map(fn {%Task{} = task, position} ->
      positions = parent_positions ++ [position]

      %{
        id: task.id,
        title: task.title,
        description: task.description,
        index: DoIt.Tasks.Index.label(positions, ctx.index_style),
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
        co_assignee_ids: Map.get(ctx.co_ids, task.id, []),
        comment_count: Map.get(ctx.comment_counts, task.id, 0),
        cross_references: references(ctx.outgoing, task.id, ctx.label_index, :target),
        referenced_by: references(ctx.incoming, task.id, ctx.label_index, :source),
        children: task_nodes(task.children, ctx, positions, depth + 1)
      }
    end)
  end

  # The Initiative's web URL — the operator-facing handle (m03.04 item 2.14) —
  # composed from the endpoint's public URL config via verified routes.
  defp initiative_url(id), do: url(~p"/initiatives/#{id}")

  # `[{source_id, target_id}]` -> `%{task_id => [other_id, ...]}` keyed by the
  # source (outgoing) or target (incoming) side.
  defp adjacency(links, :outgoing) do
    Enum.group_by(links, fn {source, _target} -> source end, fn {_source, target} -> target end)
  end

  defp adjacency(links, :incoming) do
    Enum.group_by(links, fn {_source, target} -> target end, fn {source, _target} -> source end)
  end

  # Resolve a task's adjacent link ids to reference entries carrying the other
  # task's id + its LIVE index label (and title). A `nil` lookup (an endpoint not
  # in the live tree — e.g. soft-deleted) is dropped, so the reference never rots.
  defp references(adjacency, task_id, label_index, role) do
    adjacency
    |> Map.get(task_id, [])
    |> Enum.flat_map(fn other_id ->
      case Map.get(label_index, other_id) do
        nil -> []
        %{index: index, title: title} -> [reference_entry(role, other_id, index, title)]
      end
    end)
  end

  defp reference_entry(:target, id, index, title),
    do: %{target_id: id, target_index: index, target_title: title}

  defp reference_entry(:source, id, index, title),
    do: %{source_id: id, source_index: index, source_title: title}

  @doc "The task → Initiative resolver body (`GET /api/v1/tasks/:id`)."
  def task_ref(%Task{} = task) do
    %{id: task.id, initiative_id: task.initiative_id}
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
