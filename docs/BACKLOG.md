# BACKLOG
_Last updated: 2026-06-20_

Work for releases _after_ the upcoming one. The currently-targeted release and its milestones live in [`PLAN.md`](PLAN.md); this file is for everything beyond that.

## Conventions
1. Items here are noted but not yet scoped or scheduled.
2. Promotion to a milestone is the moment of commitment — at that point the item moves to PLAN.md's milestone table and gets a milestone doc under `docs/milestones/`.
3. Don't catalog implementation detail here; one or two lines per item is enough. Scope and acceptance criteria belong in the milestone doc, not in BACKLOG.

## Items

- **Multi-select tasks (batch edit + batch move).** Select several tasks at once — Ctrl-click toggles one in/out of the selection (add/subtract), Shift-click selects a range; tasks inside a collapsed branch are excluded. The Details pane starts blank and shows only the values shared by every selected task; editing a field applies to all selected tasks where applicable (branches skip progress, leaves skip sorting). Dragging a selected task's handle moves the whole selection as a batch.
  - **Compatible (batch move):** the move reduces to the selection-roots (the shallowest selected node of each subtree), each carrying its whole subtree — a selected descendant under a selected ancestor is subsumed (no orphans), so a Shift-range may span a parent and its visible children with no pre-collapse step. Per-drop constraints: no cycle (the drop target can't sit inside any selected subtree); a reorder (edge-band drop) needs the roots to share one parent, otherwise only reparent/promote applies. Landing in a new parent follows that parent's sort mode — auto-sort places/interleaves the incoming roots per its rule; manual lands them contiguously at the drop position in their relative order.
