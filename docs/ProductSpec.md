# Product Spec
_Last updated: 2026-09-15_

The canonical specification of Do It List — what the product is, the vocabulary used to describe it, the principles it must hold to, and the headline behaviors that define it.

This is the master spec. Milestone docs and subsystem specs narrow or extend it but do not contradict it. [`PLAN.md`](PLAN.md) tracks how we get there; this doc tracks what "there" means.

## 1. Requirement Language

Specifications normally state behavior directly. Where obligation needs emphasis, **shall** marks a mandatory requirement, **should** marks the expected default, and **may** marks permitted behavior. Exceptions to a **should** are allowed and should document their reasons. This convention applies here and in subordinate specifications.

## 2. Core Idea

**Task trees with real progress.** Break work into nested tasks; update progress on leaves; parent progress rolls up automatically. Importance is expressed by decomposition: break the work that matters more into more detail, and it counts for more — there is no weight attribute to tune.

This is not a generic todo app. Nested work is first-class.

## 3. Product Inspiration

Heavily inspired by AbstractSpoon's ToDo List, with three deliberate departures:
1. Web-based, not a Windows desktop app.
2. Real-time collaborative — multiple users edit simultaneously with near-instant updates.
3. Simpler — features earn their place only if they keep the UI clean.

## 4. Vocabulary

1. **Initiative** — the top-level container; has members and many Lists. (Renamed from "Project" then to "Orchard" then to "Initiative" on 2026-05-07; see [`CHANGELOG.log`](CHANGELOG.log).)
2. **Task** — any node in the tree.
3. **List** — informal name for a *root* task (a task whose `parent_id` is null). An Initiative usually has multiple Lists, each with its own tree.
4. **Progress** — a task's current completion (0–100). Manual on leaves, computed on branches.
5. **Roll-up progress** — a branch task's computed progress: the average progress of all its descendant leaves (the leaf average).
6. **Leaf task** — a task with no children. (A metaphor term serving where the plain vocabulary has no analog — see Visual Metaphor.)
7. **Initiative member** — a `(user, initiative, role)` triple. Roles: `owner`, `editor`, `viewer`.

## 5. Visual Metaphor

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

## 6. UI/UX

Every Do It List interface follows the universal baseline in [`UX_GUARDRAILS.md`](UX_GUARDRAILS.md). This section defines product-specific interface behavior.

### 6.1 Client Interface

1. Product views render in the browser. The server may serve the bootstrap document and static assets; it does not render product views.
2. The browser owns immediate UI state. The server owns identity, permissions, validation, ordering, durable data, and live delivery.
3. Every client uses the same server-side operations. Transports may differ; product rules do not.
4. A durable change remains visibly pending until the server accepts it. Pending work survives navigation, reload, and connection loss; rejected editable input remains recoverable.
5. During server disruption, last-known content remains readable. Local view actions keep working, and durable changes that do not require current server information queue visibly.
6. Actions requiring current server information state that they are unavailable immediately.
7. Reconnection reconciles durable server state with pending work. Repeated failure ends in a clear offline state with Retry, never an endless reconnect loop.

### 6.2 Task Tree Display

The task tree stays readable at any viewport and degrades by scrolling, never by crushing content.

1. **Readability floor.** A task's content never compresses below a usable minimum width; chips and title stay legible regardless of nesting depth or screen size.
2. **Scroll over squeeze.** When the tree needs more width than is available — deep nesting, a narrow screen, or both — the task area scrolls horizontally rather than squeezing content into an unreadable sliver.
3. **Uniform top-level width.** All top-level tasks in an Initiative render at the same width, so the tree reads as one coherent column instead of a ragged stack.
4. **Titles wrap, never truncate.** A long title wraps to as many lines as it needs at its row's width; it is never clipped with an ellipsis. (Descriptions may truncate; titles do not.)
5. **Depth drives width, not text.** How far the tree extends horizontally follows its visible nesting depth — a single long title never widens the whole tree. Collapsing a branch reduces that depth.
6. **Visible work only.** Tree interactions and rendering process visible and changed Tasks, not the entire Initiative.

## 7. Durable Principles

1. **Nested work is first-class.** The tree is the point.
2. **Progress is useful by default.** Roll-up needs no configuration to be meaningful.
3. **Importance is expressed by decomposition, not configuration.** To make a branch count for more, break it into more leaves — there is no weight attribute. The side effect is virtuous: the work that matters most ends up specified in the most detail.
4. **No file check-in/check-out collaboration.** Real-time, last-writer-wins by default.
5. **Grow milestone by milestone.** Resist becoming bloated PM software.

## 8. Roll-up Progress (principle + formula)

Leaf tasks use manual progress. Branch tasks use the **leaf average** (per the AbstractSpoon inspiration): the plain average over **all descendant leaves** — every leaf counts one unit, wherever it sits in the subtree:

```
sum(leaf_progress) / leaf_count
```

Because every leaf counts the same, a subtree's pull on its ancestors is its leaf count — decomposing a branch further is how the user makes it matter more. The Initiative header bar is the system root's roll-up — the same math end to end.

Two alternate formulas are available as a per-initiative setting (Initiative pane → Settings → Progress calculation); leaf average is the default.

1. **Single-level average** — the original formula. Each direct child counts as one unit regardless of how many leaves it contains.
2. **Depth-weighted leaf average** — the leaf average, damped by nesting. A leaf's pull on an ancestor falls by 10% for every branch level that sits between them:

   ```
   weight(leaf)   = 1
   weight(branch) = 0.9 × sum of children's weights

   progress(branch) = sum(weight(child) × progress(child)) / sum(weight(child))
   ```

   A subtree's weight in its parent, for a subtree of 90 leaves and for a single branch holding two:

   | Subtree | Leaf average | Depth-weighted |
   |---|---|---|
   | 90 leaves, flat | 90 | 81 |
   | 90 leaves, nested four deep | 90 | 59 |
   | 2 leaves under one branch | 2 | 1.8 |

   The damping is a discount, not a transfer — nothing moves sideways to siblings, so a subtree's weight never reaches zero and never goes negative, and every added leaf still adds. **Rejected:** the toll variant, where a branch counts as two leaf-units and funds that out of its own posterity by paying its leaf siblings. It zeroes a two-leaf branch, hands a windfall to a lone leaf sitting among branch siblings, and has no recipient at all when every sibling is a branch.

   Detail still adds — a branch is always worth more the more leaves it holds — but each added layer of decomposition adds a little less than the last. It answers the case where work is decomposed late and in depth as a deadline nears, and the fresh detail swamps the bar it was meant to clarify. The 0.9 damping factor is a fixed constant, not a setting: importance stays a matter of decomposition, not configuration.

Edge cases (status transitions, root-task behavior) are owned by the milestone doc that introduced them — currently [`milestones/m01-baseapp/m01-baseapp.md`](milestones/m01-baseapp/m01-baseapp.md) → "Progress Rules".

## 9. Task completion cascade

1. Marking a parent task done cascades the done state to all descendants. The user confirms first.
2. Unchecking a leaf cascades the undone state up the ancestor chain — any ancestor that was done becomes undone, since a parent can only be done if all its descendants are done. No confirm needed.

## 10. Reorganization

_Added 2026-05-19; operator-approved 2026-05-20._

The user reshapes the tree as work evolves. Four concepts:

### 10.1 Reparent

Change a task's parent.

1. Allowed within an Initiative, including cross-List moves — a task in one List can become a child of a task in a different List of the same Initiative.
2. After a Reparent, roll-up progress recomputes for both the old and new ancestor chains. Status reconciliation may also flip ancestors' completion state when the new child set crosses a completeness boundary.

### 10.2 Promotion

Make a non-root task a root task (a task whose `parent_id` is null). The reverse direction — a root task becoming a non-root child — is just Reparent.

1. Same Initiative.
2. Old ancestor chain recomputes per Reparent's rules; the new "chain" is the root level (no ancestors).
3. Triggered by dragging a non-root task into the top or bottom drop-zone overlay at the root level (see Drag mechanics).

### 10.3 Sibling reorder

Change a task's position among its current siblings without changing its parent.

1. The order is meaningful — it's how the user prioritizes work within a single parent.
2. Does not affect roll-up progress (the math is order-independent).
3. A Sibling reorder action (drag or keyboard) automatically switches the parent's sort mode to manual and overwrites the manual order with the new child sequence.
4. At the root level, the top and bottom drop-zone overlays serve double duty: dragging a root task into them reorders the root list, placing the task at the top or bottom of the roots.

### 10.4 Sibling sort

Apply an ordering rule to one parent's children.

1. Available criteria: alphabetical (by title), by status, by computed progress, by priority, by created date, by updated date.
2. The sort mode is a preference that cascades from User → Initiative → List → each parent task, with "inherit from ancestor" as the implicit default at every level. Any level may explicitly override; the closest explicit setting wins. (User-level preferences are not yet specified; when user preferences arrive, sort mode is one of them.)
3. An optional **resort all posterity** helper propagates a parent's current sort mode down its subtree. Non-mandatory; not automatic.

### 10.5 Constraints

1. No cycles. A task cannot become its own ancestor.
2. Same Initiative on both sides of every Reorganization.
3. Roll-up progress recomputes after every Reparent and Promotion; Sibling reorder and Sibling sort do not change the math.
4. Status reconciliation fires on Reparent and Promotion, not on reorder or sort.

### 10.6 Drag mechanics

Drop-band semantics differentiate the four concepts within a single drag gesture. The cursor's vertical position over a target row picks the intent:

1. **Center band** (~middle 50% of the row) → Reparent. The dragged task becomes a child of the row's task.
2. **Top edge band** (~upper 25% of the row) → Sibling reorder, landing *above* that row.
3. **Bottom edge band** (~lower 25% of the row) → Sibling reorder, landing *below* that row.
4. **Top overlay** (above the first root) → Promotion if the dragged task is non-root; root-list reorder to the top if the dragged task is already a root.
5. **Bottom overlay** (below the last root) → Promotion if non-root; root-list reorder to the bottom if already a root.

A visual placeholder appears in the destination position during drag so the user sees where the drop will land. The drop-zone overlays render only while a drag is active.

### 10.7 Keyboard

1. `Alt+↑/↓` — Sibling reorder.
2. `Alt+←/→` — Dedent / indent (which IS Reparent).

### 10.8 New-task placement defaults

1. **Auto-sorted parent.** New task lands wherever the parent's sort places it.
2. **Manual parent, created via the new-task entry form.** New task lands at the form's position — which is wherever the user invoked "+ New Sibling" or "+ New Subtask," so it can be anywhere in the sibling list.
3. **Task moved in from a different parent.** Lands at the top of the new parent, unless the new parent's auto-sort overrides.

### 10.9 Optional / future

- **Cross-Initiative reorganization.** Not currently supported.

## 11. Collaboration Model

1. Multiple users may open the same Initiative simultaneously.
2. Accepted changes propagate to other active users promptly.
3. The server establishes one order for accepted changes, and every client converges on the resulting durable state.
4. Last writer wins. No check-in/check-out, editing locks, or separate conflict-resolution workflow.
5. Each task records who last updated it and when, accessible in the UI.
6. Each accepted change is validated, persisted, and serialized once. Delivery to collaborators adds no per-recipient database read or product-view rendering.
7. Concurrent field editing stays visible and non-blocking: no locks or mandatory conflict prompts, and neither local drafts nor incoming values disappear silently.

## 12. Agent Integration

The canonical behavior for AI-agent clients lives in the subordinate [Agent Integration specification](specs/agent_integration.md).
