# BACKLOG
_Last updated: 2026-08-12_

Work for releases _after_ the upcoming one. The currently-targeted release and its milestones live in [`PLAN.md`](PLAN.md); this file is for everything beyond that.

## Conventions
1. Items here are noted but not yet scoped or scheduled.
2. Promotion to a milestone is the moment of commitment — at that point the item moves to PLAN.md's milestone table and gets a milestone doc under `docs/milestones/`.
3. Don't catalog implementation detail here; one or two lines per item is enough. Scope and acceptance criteria belong in the milestone doc, not in BACKLOG.

## Items

- **Hide fully completed tasks (workspace toggle).** An obvious toggle on the tree that hides 100%-done tasks — obvious meaning its ON state stays loudly visible as a signifier, so an accidental click never leaves someone hunting for tasks that are merely filtered. Candidate seed of a later multi-filter feature (status/assignee/priority sharing the same visible-filter-state treatment). In-house precedent: Assigned-to-Me already hides completed tasks behind its "Show completed" reveal toggle (m02.08) — reuse its behavior and wording.
- **Task descriptions below the progress bar (Initiative-level setting).** An Initiative-level toggle that shows each task's description inline in the tree row, beneath its progress bar, instead of only in the Details pane.
- **Hide progress bars (Initiative-level setting, with a viewer-only variant).** An Initiative-level toggle to hide progress bars from the tree entirely. A second variant scopes the hide to viewers only — in that mode a viewer+ still sees progress bars, but only on their own subtree (the tasks they lead — the existing `viewer_plus_led_ids` scope), while a plain viewer sees none.
- **Live-sync the Initiatives list.** Creating an Initiative (or gaining membership on one) doesn't broadcast anywhere, so another already-open Initiatives index/workspace view doesn't pick it up live — only on next visit/refresh. Found via M03's MCP testing (Arc 3), but it's a base-app gap: two browser tabs have the same behavior today.
- **Initiative-level numbering offset.** A per-Initiative start number so the index begins at the real milestone number (e.g. `19.x`) without placeholder Milestone tasks — the index is purely positional today. Include API/MCP exposure so an agent can set it. Surfaced in M03 Arc 3's nitpick session; the skill uses placeholder M-tasks until this lands.
- **Break out Initiative Settings into its own pane.** Move the Initiative Settings section out of the Details pane into a separate, collapsed-by-default pane that sits below the Initiative Details pane and appears whenever that pane is visible.
- **Per-Initiative chat mute.** Silence a chosen Initiative's incoming-chat sound — follow-up to M04's session-tied chat upgrade if busy chats elsewhere get noisy.
- **Progress measurements behind the percentage.** Store the measurement with manual progress — numerator, denominator, label (e.g. remaining/total files) — distinguish measured, estimated, and derived sources, and coalesce high-frequency progress events in the activity feed. From the Initiative 64 migration feedback (2026-08): a filesystem watcher's one-point updates were useful on the task, noisy in the feed.
- **Lightweight execution-order semantics.** An Initiative option declaring sibling order the intended execution order, a blocked/dependency signal, and a next-actionable read (completion + blocking + tree order) — explicitly not a scheduling engine. From the Initiative 64 feedback: an agent skipped past an inactionable task where the operator expected it moved into place.
- **Name the progress-calc method at aggregate surfaces.** Show which calculation produced a rolled-up percentage wherever aggregate progress appears, so Initiative 64's 99% under `leaf_average` — with one consequential cutover leaf still open — reads as what it is. The method stays the user's choice; this only labels it.
