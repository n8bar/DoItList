# Product Spec
_Last updated: 2026-06-11_

The canonical specification of Do It List — what the product is, the vocabulary used to describe it, the principles it must hold to, and the headline behaviors that define it.

This is the master spec. Milestone docs and subsystem specs narrow or extend it but do not contradict it. [`PLAN.md`](PLAN.md) tracks how we get there; this doc tracks what "there" means.

## Core Idea
**Task trees with real progress.** Break work into nested tasks; update progress on leaves; parent progress rolls up automatically. Importance is expressed by decomposition: break the work that matters more into more detail, and it counts for more — there is no weight attribute to tune.

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
- **Roll-up progress** — a branch task's computed progress: the average progress of all its descendant leaves (the leaf average).
- **Leaf task** — a task with no children. (A metaphor term serving where the plain vocabulary has no analog — see Visual Metaphor.)
- **Initiative member** — a `(user, initiative, role)` triple. Roles: `owner`, `editor`, `viewer`.

## Visual Metaphor
The product borrows a botanical metaphor at the icon layer — formal names stay plain (a List is never called a "Tree" in UI copy). Two exceptions: examples may speak the metaphor freely, and a metaphor term may serve where the plain vocabulary has no analog (e.g. **leaf task**).

- **Initiative** — represented by a 🌲🌳 small-grove icon (Lucide `trees`); it holds multiple Lists.
- **List** — represented by a 🌳 tree icon (Lucide `tree-deciduous` / `tree-pine`); each List is one tree of nested tasks within an Initiative.
- **Task with children** — represented by a branch icon.
- **Leaf task** (no children) — represented by a 🍃 leaf icon (Lucide `leaf`).

Visual nesting goes many → one → part → tip: grove of trees → one tree → branch → leaf.

Reserved for future use — the names are claimed now to prevent vocabulary drift if/when a goals concept arrives:

- **Fruit** — a single per-Tree (per-List) goal. What a tree yields.
- **Crop** — Initiative-wide aggregate goals. The harvest across multiple trees.

These are reserved only; no Fruit/Crop concept exists today.

## Task Tree Display
The task tree stays readable at any viewport and degrades by scrolling, never by crushing content.

- **Readability floor.** A task's content never compresses below a usable minimum width; chips and title stay legible regardless of nesting depth or screen size.
- **Scroll over squeeze.** When the tree needs more width than is available — deep nesting, a narrow screen, or both — the task area scrolls horizontally rather than squeezing content into an unreadable sliver.
- **Uniform top-level width.** All top-level tasks in an Initiative render at the same width, so the tree reads as one coherent column instead of a ragged stack.
- **Titles wrap, never truncate.** A long title wraps to as many lines as it needs at its row's width; it is never clipped with an ellipsis. (Descriptions may truncate; titles do not.)
- **Depth drives width, not text.** How far the tree extends horizontally follows its visible nesting depth — a single long title never widens the whole tree. Collapsing a branch reduces that depth.

## Durable Principles
- **Nested work is first-class.** The tree is the point.
- **Progress is useful by default.** Roll-up needs no configuration to be meaningful.
- **Importance is expressed by decomposition, not configuration.** To make a branch count for more, break it into more leaves — there is no weight attribute. The side effect is virtuous: the work that matters most ends up specified in the most detail.
- **No file check-in/check-out collaboration.** Real-time, last-writer-wins by default.
- **Grow milestone by milestone.** Resist becoming bloated PM software.

## Roll-up Progress (principle + formula)
Leaf tasks use manual progress. Branch tasks use the **leaf average** (per the AbstractSpoon inspiration): the plain average over **all descendant leaves** — every leaf counts one unit, wherever it sits in the subtree:

```
sum(leaf_progress) / leaf_count
```

Because every leaf counts the same, a subtree's pull on its ancestors is its leaf count — decomposing a branch further is how the user makes it matter more. The Initiative header bar is the system root's roll-up — the same math end to end.

The previous formula — the single-level average, where each direct child counts as one unit regardless of how many leaves it contains — is available as a per-initiative setting (Initiative pane → Settings → Progress calculation); leaf average is the default.

Edge cases (status transitions, root-task behavior) are owned by the milestone doc that introduced them — currently [`milestones/m01-baseapp/m01-baseapp.md`](milestones/m01-baseapp/m01-baseapp.md) → "Progress Rules".

## Task completion cascade
- Marking a parent task done cascades the done state to all descendants. The user confirms first.
- Unchecking a leaf cascades the undone state up the ancestor chain — any ancestor that was done becomes undone, since a parent can only be done if all its descendants are done. No confirm needed.

## Reorganization
_Added 2026-05-19; operator-approved 2026-05-20._

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

- Available criteria: alphabetical (by title), by status, by computed progress, by priority, by created date, by updated date.
- The sort mode is a preference that cascades from User → Initiative → List → each parent task, with "inherit from ancestor" as the implicit default at every level. Any level may explicitly override; the closest explicit setting wins. (User-level preferences are not yet specified; when user preferences arrive, sort mode is one of them.)
- An optional **resort all posterity** helper propagates a parent's current sort mode down its subtree. Non-mandatory; not automatic.

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
- **Cross-Initiative reorganization.** Not currently supported.

## Collaboration Model
- Multiple users may open the same Initiative simultaneously.
- Changes save immediately and propagate to other active users promptly — and the propagation work scales with the size of the change, not the size of the tree or the team, so "near-instant" holds as both grow.
- Last writer wins. No check-in/check-out, no file locking, no conflict resolution UI.
- Each task records who last updated it and when, accessible in the UI.
