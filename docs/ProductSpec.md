# Product Spec
_Last updated: 2026-05-19_

The canonical specification of Do It List — what the product is, the vocabulary used to describe it, the principles it must hold to, and the headline behaviors that define it.

This is the master spec. Milestone docs and subsystem specs narrow or extend it but do not contradict it. [`PLAN.md`](PLAN.md) tracks how we get there; this doc tracks what "there" means.

## Core Idea
**Task trees with real progress.** Break work into nested tasks; update progress on leaves; parent progress rolls up automatically. Weighting is optional but available for users who need accuracy.

This is not a generic todo app. Nested work is first-class.

## Product Inspiration
Heavily inspired by AbstractSpoon's ToDo List, with three deliberate departures:
1. Web-based, not a Windows desktop app.
2. Real-time collaborative — multiple users edit simultaneously with near-instant updates.
3. Simpler — features earn their place only if they keep the UI clean.

## Vocabulary
- **Initiative** — the top-level container; has members and many Lists. (Renamed from "Project" then to "Orchard" then to "Initiative" on 2026-05-07; see [`CHANGELOG.log`](CHANGELOG.log).)
- **Task** — any node in the tree.
- **List** — informal name for a *root* task (a task whose `parent_id` is null). An Initiative usually has multiple Lists, each with its own tree.
- **Progress** — a task's current completion (0–100). Manual on leaves, computed on branches.
- **Roll-up progress** — a branch task's computed progress: the weighted average of its children's rolled-up progress.
- **Weight** — how much a child contributes to its parent's roll-up. Default `1`.
- **Initiative member** — a `(user, initiative, role)` triple. Roles: `owner`, `editor`, `viewer`.

## Visual Metaphor
The product borrows a botanical metaphor at the icon layer only — the formal vocabulary above stays plain:

- **Initiative** — represented by a 🌲🌳 small-grove icon (Lucide `trees`); it holds multiple Lists.
- **List** — represented by a 🌳 tree icon (Lucide `tree-deciduous` / `tree-pine`); each List is one tree of nested tasks within an Initiative.
- **Task with children** — represented by a branch icon.
- **Leaf task** (no children) — represented by a 🍃 leaf icon (Lucide `leaf`).

Visual nesting goes many → one → part → tip: grove of trees → one tree → branch → leaf.

Reserved for future use — the names are claimed now to prevent vocabulary drift if/when a goals concept arrives:

- **Fruit** — a single per-Tree (per-List) goal. What a tree yields.
- **Crop** — Initiative-wide aggregate goals. The harvest across multiple trees.

These are reserved only; no Fruit/Crop concept exists today.

## Durable Principles
- **Nested work is first-class.** The tree is the point.
- **Progress is useful by default.** A user who never touches weights still gets meaningful roll-up.
- **Weighting is optional, never required.** Users opt in to non-equal contributions.
- **No file check-in/check-out collaboration.** Real-time, last-writer-wins by default.
- **Grow milestone by milestone.** Resist becoming bloated PM software.

## Roll-up Progress (principle + formula)
Leaf tasks use manual progress. Branch tasks use computed progress:

```
sum(child_progress * child_weight) / sum(child_weight)
```

Roll-up is recursive through ancestors. Edge cases (non-positive weights, status transitions, root-task behavior) are owned by the milestone doc that introduced them — currently [`milestones/m01-baseapp/m01-baseapp.md`](milestones/m01-baseapp/m01-baseapp.md) → "Progress Rules".

## Reorganization
_Draft — pending owner approval. Added 2026-05-19._

The user reshapes the tree as work evolves. Four concepts:

### Reparent
Change a task's parent.

- Allowed within an Initiative, including cross-List moves — a task in one List can become a child of a task in a different List of the same Initiative.
- After a Reparent, roll-up progress recomputes for both the old and new ancestor chains. Status reconciliation may also flip ancestors' completion state when the new child set crosses a completeness boundary.

### Promotion
Make a non-root task a root task (a task whose `parent_id` is null). The reverse direction — a root task becoming a non-root child — is just Reparent.

- Same Initiative.
- Old ancestor chain recomputes per Reparent's rules; the new "chain" is the root level (no ancestors).
- Triggered by dragging a non-root task into the top or bottom drop-zone overlay at the root level (see Drag mechanics).

### Sibling reorder
Change a task's position among its current siblings without changing its parent.

- The order is meaningful — it's how the user prioritizes work within a single parent.
- Does not affect roll-up progress (the math is order-independent).
- A Sibling reorder action (drag or keyboard) automatically switches the parent's sort mode to manual and overwrites the manual order with the new child sequence.
- At the root level, the top and bottom drop-zone overlays serve double duty: dragging a root task into them reorders the root list, placing the task at the top or bottom of the roots.

### Sibling sort
Apply an ordering rule to one parent's children.

- Available criteria: alphabetical (by title), by status, by computed progress, by priority, by weight, by created date, by updated date.
- The sort mode is a preference that cascades from User → Initiative → List → each parent task, with "inherit from ancestor" as the implicit default at every level. Any level may explicitly override; the closest explicit setting wins. (User-level preferences are not yet specified; when user preferences arrive, sort mode is one of them.)
- An optional **resort all posterity** helper lets the owner of a parent propagate the current sort mode down its subtree. Non-mandatory; not automatic.

### Constraints
- No cycles. A task cannot become its own ancestor.
- Same Initiative on both sides of every Reorganization.
- Roll-up progress recomputes after every Reparent and Promotion; Sibling reorder and Sibling sort do not change the math.
- Status reconciliation fires on Reparent and Promotion, not on reorder or sort.

### Drag mechanics
Drop-band semantics differentiate the four concepts within a single drag gesture. The cursor's vertical position over a target row picks the intent:

- **Center band** (~middle 50% of the row) → Reparent. The dragged task becomes a child of the row's task.
- **Top edge band** (~upper 25% of the row) → Sibling reorder, landing *above* that row.
- **Bottom edge band** (~lower 25% of the row) → Sibling reorder, landing *below* that row.
- **Top overlay** (above the first root) → Promotion if the dragged task is non-root; root-list reorder to the top if the dragged task is already a root.
- **Bottom overlay** (below the last root) → Promotion if non-root; root-list reorder to the bottom if already a root.

A visual placeholder appears in the destination position during drag so the user sees where the drop will land. The drop-zone overlays render only while a drag is active.

### Keyboard
- `Alt+↑/↓` — Sibling reorder.
- `Alt+←/→` — Dedent / indent (which IS Reparent).

### New-task placement defaults
- **Auto-sorted parent.** New task lands wherever the parent's sort places it.
- **Manual parent, created via the new-task entry form.** New task lands at the form's position — which is wherever the user invoked "+ New Sibling" or "+ New Subtask," so it can be anywhere in the sibling list.
- **Task moved in from a different parent.** Lands at the top of the new parent, unless the new parent's auto-sort overrides.

### Optional / future
- **Cross-Initiative reorganization.** Not currently supported. Not foreclosed either; if/when it lands, it'll require deciding whether the Initiative is a strict boundary or a soft default.

## Collaboration Model
- Multiple users may open the same Initiative simultaneously.
- Changes save immediately and propagate to other active users promptly.
- Last writer wins. No check-in/check-out, no file locking, no conflict resolution UI.
- Each task records who last updated it and when, accessible in the UI.
