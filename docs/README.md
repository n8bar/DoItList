# Docs

This folder organizes the project's documentation. This file describes how it's organized — doc roles, hierarchy, and conventions — so you (or an agent) know where to put new docs and where to find the rules.

For working style and engineering rules, see [`../CLAUDE.md`](../CLAUDE.md). For *what we're building*, see [`ProductSpec.md`](ProductSpec.md). For *what we're doing about it*, see [`PLAN.md`](PLAN.md).

## Doc Roles

Two top-level docs sit at level 1 of the hierarchy, split by purpose:
- **[`PLAN.md`](PLAN.md)** — master *action* list. Milestones, status, deferred decisions, what's next. *How we get there.*
- **[`ProductSpec.md`](ProductSpec.md)** — master *spec*. Vocabulary, principles, behaviors, invariants. *What "there" means.*

[`../CLAUDE.md`](../CLAUDE.md) sits above the split as the always-loaded primer — not a spec, not an action list, just whatever should be in context regardless of what we're working on.

Other level-1 docs:
- **[`BACKLOG.md`](BACKLOG.md)** — work for releases after the current target.
- **[`UX_GUARDRAILS.md`](UX_GUARDRAILS.md)** — universal UX/a11y baseline + project-specific additions.
- **[`CHANGELOG.log`](CHANGELOG.log)** — chronological record of scope/requirement/doc-structure changes. One concise line per change (the what + a brief why; no implementation detail). Rotate to `CHANGELOG.archive.log` when it grows unwieldy.

## Action-list Hierarchy

Below PLAN.md:

```
PLAN.md
  Milestone     coherent shippable slice of the product
    Arc         focused slab of work within a milestone
      Worklist  sequenced list of Items belonging to one Arc
        Item    leaf action (a single concrete task)
          Subitem  finer-grained sub-action (only inside a Worklist)
      Item    leaf directly under an Arc — shortcut for a single-Item Worklist
```

Adding Subitems to an Arc-level Item decompresses the shortcut: that Item should be written as a proper Worklist with its own Items.

**Docs stop at Worklist.** Items and Subitems live as inline checklist content inside their parent Worklist; they never get their own files.

**Stay at your altitude.** A higher-level doc summarizes intent, names the thing, and links down. It does not catalog the same level of detail as its child docs. If PLAN.md or ProductSpec.md starts listing edge cases or per-task steps, that content belongs lower.

## Conventions

### 1. Numbering
1.1 Milestones use `m##` (zero-padded, lowercase, ceiling 99): `m01`, `m02`, …
1.2 Arcs are numbered within their milestone: `m##.NN` — e.g. `m02.01`, `m02.02`, … In Arc headings inside a milestone doc, use the local number only: `### 1 — <name>`. Do not repeat the dotted form in the heading.
1.3 Worklists are numbered within their arc: `m##.NN.NN` — e.g. `m02.01.01`.
1.4 Items use plain Markdown numbered checkboxes inside their parent Worklist; Subitems use nested checkboxes. Checkboxes (`[ ]` / `[x]`) attach only to actionable items — never to action-list titles or headings (Milestone, Arc, Worklist) at any level. **Items must not prefix themselves with their own dotted reference** — position in the doc gives the reference. `1. [ ] Audit the app...` ✓ — `1. [ ] **m02.01.01** — Audit the app...` ✗.
1.5 References in prose extend the dotted form down to Item and Subitem positions: `m02.01.01.05.03` = milestone 2 / arc 1 / worklist 1 / item 5 / subitem 3. Cross-references between items are fine; self-labels on items are not.
1.6 References are tolerant: padding optional, leading `m`/`M` case-insensitive. `m02.1.1.5.3`, `M02.1.1`, and `m02.01.01.05.03` are equivalent. Filenames are strict — always padded, always lowercase.
1.7 Within a milestone doc, the milestone prefix may be omitted from references when context implies it (`.04.03.02.05`).

### 2. Doc Layout
2.1 Milestone docs live at `docs/milestones/m##-<slug>/m##-<slug>.md`.
2.2 Arc and Worklist content default to inline within the milestone doc.
2.3 Optional breakouts as flat siblings:
   - Arc: `docs/milestones/m##-<slug>/m##.NN-<slug>.md`
   - Worklist: `docs/milestones/m##-<slug>/m##.NN.NN-<slug>.md`
2.4 If breakouts get crowded, introduce arc subfolders: `docs/milestones/m##-<slug>/m##.NN-<slug>/...`.
2.5 Subordinate specs are content-named (not milestone-named) and live at `docs/specs/<topic>.md`.

### 3. Specs vs. Action lists
3.1 Specs describe behavior and invariants; action lists describe how/when work happens.
3.2 Action lists may reference specs but aren't required to — they may simply subdivide their parent's goal.
3.3 Specs do not refer back to action lists.

### 4. Milestone deadlines
4.1 Every milestone carries a target date. Set the target when the milestone is scoped — `TBD` is allowed only for milestones still pending a scoping pass.
4.2 Approximate dates are fine and should be marked: `~2026-08-15` for "around mid-August," `~2026-Q3` for quarter precision.
4.3 Completed milestones record their actual completion date in the Completed Milestones table.

### 5. Testing assignee tags
5.1 Subitems under a Testing item carry an assignee tag marking who performs that verification:
   - `[Agent]` — the primary agent (Claude) working solo.
   - `[Subagent]` — Claude fanning the work out to parallel-forked subagents.
   - `[Human]` — the operator only.
   - `[Guided]` — Claude and the operator together.
5.2 The tag prefixes the subitem text. Define them only here — don't repeat the key in arc docs.

### 6. Omissions & Corrections
6.1 An arc doc may carry an `## Omissions & Corrections` section for bigger-than-tweak gaps whose home arc has closed — bugs and accidental omissions from earlier arcs. Any arc may pick such work up; the section is where the work gets documented first.
6.2 Small tweaks never go here — those are fixed on the spot with a CHANGELOG line only.
6.3 It's a work section, not a parking lot: its items are done within that arc. If the arc closes with one unfinished, the item moves to another arc explicitly.

> Branch naming and repo workflow rules (specs-first, don't-merge-dirty, `main` canonical) live in [`../CLAUDE.md`](../CLAUDE.md) since they apply regardless of doc context.
