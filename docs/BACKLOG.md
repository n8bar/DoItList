# BACKLOG
_Last updated: 2026-06-20_

Work for releases _after_ the upcoming one. The currently-targeted release and its milestones live in [`PLAN.md`](PLAN.md); this file is for everything beyond that.

## Conventions
1. Items here are noted but not yet scoped or scheduled.
2. Promotion to a milestone is the moment of commitment — at that point the item moves to PLAN.md's milestone table and gets a milestone doc under `docs/milestones/`.
3. Don't catalog implementation detail here; one or two lines per item is enough. Scope and acceptance criteria belong in the milestone doc, not in BACKLOG.

## Items

- **Multi-select tasks (batch edit + batch move).** Select several tasks at once — Ctrl-click toggles one in/out of the selection (add/subtract), Shift-click selects a range; tasks inside a collapsed branch are excluded. The Details pane starts blank and shows only the values shared by every selected task; editing a field applies to all selected tasks where applicable (branches skip progress, leaves skip sorting). When the selection is *compatible*, dragging one task's handle moves/reorders the whole selection as a batch.
  - Open question: define "compatible" (which selections may be batch-moved/reordered).
