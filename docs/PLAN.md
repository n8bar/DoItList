# PLAN
_Last updated: 2026-05-06_

Human-facing execution dashboard for Do It List. Open this doc first when resuming work.

Use [`CLAUDE.md`](../CLAUDE.md) for working style and engineering rules.
Use [`ProductSpec.md`](ProductSpec.md) for product behavior and invariants.
Use milestone docs under `docs/milestones/m##-<slug>/` for milestone scope and acceptance criteria.

## Doc Roles
Two top-level docs sit at level 1 of the hierarchy, split by purpose:
- **PLAN.md** — master *action* list. Milestones, status, deferred decisions, what's next. *How we get there.*
- **[`ProductSpec.md`](ProductSpec.md)** — master *spec*. Vocabulary, principles, behaviors, invariants. *What "there" means.*

[`CLAUDE.md`](../CLAUDE.md) sits above the split as the always-loaded primer — not a spec, not an action list, just whatever should be in context regardless of what we're working on.

Other level-1 docs:
- **[`BACKLOG.md`](BACKLOG.md)** — work for releases after the current target.
- **[`FINDINGS.md`](FINDINGS.md)** — observation log; action lists reference findings by ID.
- **[`UX_GUARDRAILS.md`](UX_GUARDRAILS.md)** — universal UX/a11y baseline + project-specific additions.
- **[`CHANGELOG.log`](CHANGELOG.log)** — chronological record of scope/requirement/doc-structure changes.

The action-list hierarchy below PLAN.md:

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
1.2 Arcs are numbered within their milestone: `m##.NN` — e.g. `m02.01`, `m02.02`, …
1.3 Worklists are numbered within their arc: `m##.NN.NN` — e.g. `m02.01.01`.
1.4 Items use plain Markdown numbered checkboxes inside their parent Worklist; Subitems use nested checkboxes.
1.5 References in prose extend the dotted form down to Item and Subitem positions: `m02.01.01.05.03` = milestone 2 / arc 1 / worklist 1 / item 5 / subitem 3.
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

### 4. Branches
4.1 Milestone-scoped work: `M##-<slug>` (uppercase M, no padding). Example: `M02-keyboard-nav`.
4.2 Non-milestone work uses semantic prefixes: `fix/<slug>`, `chore/<slug>`, `docs/<slug>`, `spike/<slug>`.

### 5. Repo
5.1 `main` is canonical on GitHub.
5.2 Specs-first: a milestone doc with acceptance criteria exists before its code lands.
5.3 Don't merge with a dirty tree or unpushed commits without explicit confirmation.

### 6. Milestone deadlines
6.1 Every milestone carries a target date. Set the target when the milestone is scoped — `TBD` is allowed only for milestones still pending a scoping pass.
6.2 Approximate dates are fine and should be marked: `~2026-08-15` for "around mid-August," `~2026-Q3` for quarter precision.
6.3 Completed milestones record their actual completion date in the Completed Milestones table.

## Deferred Decisions
Decisions consciously postponed. Each entry names the trigger that should make us revisit it.

| Decision | Defer until | Rationale |
|---|---|---|
| Branch protection on `main` (require PR, status checks, etc.) | A second contributor joins the repo | Solo dev — protection is friction with no review benefit. |
| GitHub Actions CI (`mix test`, build, etc.) | A second contributor joins the repo | Tests run locally in the dev container; remote CI is overhead until shared review matters. |

## Current
- Active milestone: **M01-BaseApp** — scaffold complete and pushed; treating as done-as-scoped.
- Status: `complete (per m01-baseapp.md acceptance criteria)`
- Next action: scope **M02** (UX Overhaul). Write the milestone doc at `docs/milestones/m02-ux-overhaul/m02-ux-overhaul.md` before code.
- Primary next doc: _TBD — `docs/milestones/m02-ux-overhaul/m02-ux-overhaul.md` (not yet written)._

## Release Target
No public release yet. Owner will not release until at least M02 (UX Overhaul) lands and the app feels presentable.

## Milestones
| Status | ID | Milestone | Short intent | Target | Doc |
|---|---|---|---|---|---|
| [ ] | M02 | UX Overhaul | Make the app presentable: visual polish, interaction quality, mobile/responsive baseline. Scope TBD. | _TBD (set at scoping)_ | _TBD_ |

## Completed Milestones
| Status | ID | Milestone | Short intent | Completed | Doc |
|---|---|---|---|---|---|
| [x] | M01 | BaseApp | First working slice: accounts, projects, nested task tree, roll-up progress, project membership, basic activity log, Dockerized. | 2026-05-05 | [`milestones/m01-baseapp/m01-baseapp.md`](milestones/m01-baseapp/m01-baseapp.md) |
