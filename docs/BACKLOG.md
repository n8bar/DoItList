# BACKLOG
_Last updated: 2026-06-15_

Work for releases _after_ the upcoming one. The currently-targeted release and its milestones live in [`PLAN.md`](PLAN.md); this file is for everything beyond that.

## Conventions
1. Items here are noted but not yet scoped or scheduled.
2. Promotion to a milestone is the moment of commitment — at that point the item moves to PLAN.md's milestone table and gets a milestone doc under `docs/milestones/`.
3. Don't catalog implementation detail here; one or two lines per item is enough. Scope and acceptance criteria belong in the milestone doc, not in BACKLOG.

## Items

### Initiative lifecycle (M4 or later)
- **Duplicate a non-owned initiative.** Copy it into a brand-new initiative you own — new tasks, fresh timestamps, _not_ a clone of the original's history. Owners can disable duplication per-initiative, but it's a soft barrier only (manual recreation is always possible; make owners aware).
- **Trash ↔ duplicate interplay.** An owner-trashed initiative (Trash ships in `m02.06`) shows to its members as an unowned item in their Trash; unless the owner disabled duplication, they can duplicate it before it's permanently purged.

### Account (M4 or later)
- **Avatar upload.** User-supplied avatar images replacing/augmenting the generated ones from `m02.04` — brings file storage, serving, size limits, image processing.
- **Email infrastructure & invites.** A mailer plus everything gated on it: email verification on change/registration, email-based password reset, and the **invite system** — "add a member" becomes an *invite* (a pending membership that can already hold task assignments before acceptance; pending assignees show **dimmed with a dashed border** until they join). An invite reaches an existing account or an email with no matching account (auto-joining them if they later register), binds to whichever account the recipient accepts with, and shows as **pending** in the roster (removable, which cancels the tracked add). Invitees are notified in-app + by email. Until the mailer exists, forgotten passwords are admin resets (fine at private scale).

### Task row polish
- **Task indexes — deferred extras.** Beyond the fixed styles shipping in `m02.07` (item 7): **Custom Outline** (user picks the glyph set per level), a **depth-flat variant** (`1.`, `2.` per level, no ancestor prefix), and a **continue-across-collapse** toggle. (Color-coded priority pills + the fixed-style indexes themselves were promoted to `m02.07`.)

### Membership (M4 or later)
- **Taskmaster — a task-scoped full-control role.** Like viewer+ (m02.05 item 12.6) but stronger: full editor-level control over the task they're the direct assignee of *and its whole subtree* — create / delete / move / reorder / rename / re-staff within it — without any rights to the rest of the Initiative. The natural step up from viewer+ (which only grants progress / comments + pool-limited staffing) for someone you want to fully own a branch. The Initiative's second task-scoped permission.

### Templates (likely its own milestone)
- **Initiative templates.** Pre-built task trees that instantiate into a fresh Initiative — decomposition as a starting point, and a fix for the blank-canvas problem on first use. Three layers at very different sizes, worth keeping separable: (1) **curated / built-in** starter templates shipped with the app ("New Initiative from template") — smallest, highest onboarding payoff, could ship alone; (2) **save-as-template** — turn one of your Initiatives (or a subtree) into a personal reusable template; (3) **sharing / library** — give a template to another user or publish it (the big one: discovery, attribution, permissions, moderation — realistically its own milestone). A template captures the tree **skeleton** (titles, nesting, optionally priorities / sort modes / progress-calc) and instantiates **fresh** — no assignments, progress, members, activity, or co-assignees carried over. Shares machinery with "Duplicate a non-owned initiative" above (both copy a tree into a new owned Initiative).
