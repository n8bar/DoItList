# BACKLOG
_Last updated: 2026-08-11_

Work for releases _after_ the upcoming one. The currently-targeted release and its milestones live in [`PLAN.md`](PLAN.md); this file is for everything beyond that.

## Conventions
1. Items here are noted but not yet scoped or scheduled.
2. Promotion to a milestone is the moment of commitment — at that point the item moves to PLAN.md's milestone table and gets a milestone doc under `docs/milestones/`.
3. Don't catalog implementation detail here; one or two lines per item is enough. Scope and acceptance criteria belong in the milestone doc, not in BACKLOG.

## Items

- **Task descriptions below the progress bar (Initiative-level setting).** An Initiative-level toggle that shows each task's description inline in the tree row, beneath its progress bar, instead of only in the Details pane.
- **Hide progress bars (Initiative-level setting, with a viewer-only variant).** An Initiative-level toggle to hide progress bars from the tree entirely. A second variant scopes the hide to viewers only — in that mode a viewer+ still sees progress bars, but only on their own subtree (the tasks they lead — the existing `viewer_plus_led_ids` scope), while a plain viewer sees none.
- **Live-sync the Initiatives list.** Creating an Initiative (or gaining membership on one) doesn't broadcast anywhere, so another already-open Initiatives index/workspace view doesn't pick it up live — only on next visit/refresh. Found via M03's MCP testing (Arc 3), but it's a base-app gap: two browser tabs have the same behavior today.
- **Initiative-level numbering offset.** A per-Initiative start number so the index begins at the real milestone number (e.g. `19.x`) without placeholder Milestone tasks — the index is purely positional today. Include API/MCP exposure so an agent can set it. Surfaced in M03 Arc 3's nitpick session; the skill uses placeholder M-tasks until this lands.
- **Break out Initiative Settings into its own pane.** Move the Initiative Settings section out of the Details pane into a separate, collapsed-by-default pane that sits below the Initiative Details pane and appears whenever that pane is visible.
- **Per-Initiative chat mute.** Silence a chosen Initiative's incoming-chat sound — follow-up to M04's session-tied chat upgrade if busy chats elsewhere get noisy.
