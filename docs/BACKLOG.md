# BACKLOG
_Last updated: 2026-09-14_

Work for releases _after_ the upcoming one. The currently-targeted release and its milestones live in [`PLAN.md`](PLAN.md); this file is for everything beyond that.

## Conventions
1. Items here are noted but not yet scoped or scheduled.
2. Promotion to a milestone is the moment of commitment — at that point the item moves to PLAN.md's milestone table and gets a milestone doc under `docs/milestones/`.
3. Don't catalog implementation detail here; one or two lines per item is enough. Scope and acceptance criteria belong in the milestone doc, not in BACKLOG.

## Items

- **Hide progress bars (Initiative-level setting, with a viewer-only variant).** An Initiative-level toggle to hide progress bars from the tree entirely. A second variant scopes the hide to viewers only — in that mode a viewer+ still sees progress bars, but only on their own subtree (the tasks they lead — the existing `viewer_plus_led_ids` scope), while a plain viewer sees none.
- **Initiative-level numbering offset.** A per-Initiative start number so the index begins at the real milestone number (e.g. `19.x`) without placeholder Milestone tasks — the index is purely positional today. Include API/MCP exposure so an agent can set it. Surfaced in M03 Arc 3's nitpick session; the skill uses placeholder M-tasks until this lands.
- **Break out Initiative Settings into its own pane.** Move the Initiative Settings section out of the Details pane into a separate, collapsed-by-default pane that sits below the Initiative Details pane and appears whenever that pane is visible.
- **Per-Initiative chat mute.** Silence a chosen Initiative's incoming-chat sound — follow-up to M05's session-tied chat upgrade if busy chats elsewhere get noisy.
- **Progress measurements behind the percentage.** Store the measurement with manual progress — numerator, denominator, label (e.g. remaining/total files) — distinguish measured, estimated, and derived sources, and coalesce high-frequency progress events in the activity feed. From the Initiative 64 migration feedback (2026-08): a filesystem watcher's one-point updates were useful on the task, noisy in the feed.
- **Lightweight execution-order semantics.** An Initiative option declaring sibling order the intended execution order, a blocked/dependency signal, and a next-actionable read (completion + blocking + tree order) — explicitly not a scheduling engine. From the Initiative 64 feedback: an agent skipped past an inactionable task where the operator expected it moved into place.
- **Name the progress-calc method at aggregate surfaces.** Show which calculation produced a rolled-up percentage wherever aggregate progress appears, so Initiative 64's 99% under `leaf_average` — with one consequential cutover leaf still open — reads as what it is. The method stays the user's choice; this only labels it.
