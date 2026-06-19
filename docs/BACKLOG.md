# BACKLOG
_Last updated: 2026-06-15_

Work for releases _after_ the upcoming one. The currently-targeted release and its milestones live in [`PLAN.md`](PLAN.md); this file is for everything beyond that.

## Conventions
1. Items here are noted but not yet scoped or scheduled.
2. Promotion to a milestone is the moment of commitment — at that point the item moves to PLAN.md's milestone table and gets a milestone doc under `docs/milestones/`.
3. Don't catalog implementation detail here; one or two lines per item is enough. Scope and acceptance criteria belong in the milestone doc, not in BACKLOG.

## Items

### Initiative lifecycle (M4 or later)
- **Hidden — per-member.** Any member can hide an initiative from their own dashboard without touching anyone else's; restorable. Separate mechanism from Trash (promoted to `m02.06`).
- **Archive — completed initiatives.** A global "done & kept" shelf, distinct from per-member Hidden (personal view) and Trash (going away): an owner archives a wrapped initiative — restorable — dropping it from the active index + ultrawide rail into an *Archived* filter. General access from the initiatives list views; on an open initiative, hitting 100% surfaces an "Archive this Initiative" offer. Suppressible confirm when archiving one that isn't complete.
- **Duplicate a non-owned initiative.** Copy it into a brand-new initiative you own — new tasks, fresh timestamps, _not_ a clone of the original's history. Owners can disable duplication per-initiative, but it's a soft barrier only (manual recreation is always possible; make owners aware).
- **Trash ↔ duplicate interplay.** An owner-trashed initiative (Trash ships in `m02.06`) shows to its members as an unowned item in their Trash; unless the owner disabled duplication, they can duplicate it before it's permanently purged.

### Account (M4 or later)
- **Avatar upload.** User-supplied avatar images replacing/augmenting the generated ones from `m02.04` — brings file storage, serving, size limits, image processing.
- **Email infrastructure.** A mailer plus everything gated on it: email verification on change/registration, email-based password reset, and the invite-by-email flow below. Until it exists, forgotten passwords are admin resets (fine at private scale).
- **Recovery codes — the public-opening gate.** One-time codes (generated on the account page, shown once, hashed at rest) with a "use a recovery code" login path. Required before opening to the public **if** the mailer isn't live by then; unnecessary while admin resets cover everyone.
- **TOTP two-factor.** Security, not recovery — pairs with recovery codes (or a live mailer) so 2FA lockouts have an exit.

### Task row polish
- **Color-coded priority pills.** Map each priority (`high` / `low` / etc.) to its own chip color instead of the current monochrome zinc, so priority reads at a glance. Default (`normal`) stays the empty dashed placeholder. One-spot change in `task_node/1`'s priority chip.
- **Task indexes — positional numbering with selectable styles.** Render a per-task index label between the botanical icon and the pills, computed from each task's position among its siblings at every level. Selectable style (a per-Initiative or per-user preference): **Outline** (`I.A.1.a.i` — roman-upper / alpha-upper / numeric / alpha-lower / roman-lower by depth), **Numerical** (decimal/legal: `1`, `1.1`, `1.1.2`), **Roman**, **Alphabetical**, and **Custom Outline** (user picks the glyph set per level — likely its own backlog item once the fixed styles ship). **None** is the default (off). Candidate additions to weigh: a depth-flat variant (just `1.`, `2.` per level, no ancestor prefix) and a "continue across collapse" toggle. Display-only, recomputed on reorder/move; no schema (derive from sort order). Operator is open to more styles.

### Add Task UI
- **Esc closes the New Task UI.** Pressing Esc dismisses the add-task form and discards the typed title — no confirm. An explicit exception to keyboard-shortcut suppression: Esc fires even while the title textbox is focused (it edits no text, so it won't disturb typing). Pairs with the Esc-closes pattern on the delete / transfer confirms.
- **Arrow keys reposition the add-task form.** While the add-task title textbox is focused, Up / Down walk the form's insertion point through the task list — placing the new task without the mouse. Left / Right stay with the text cursor, so Up / Down carry all of it; that works because the tree reads as a vertical indented outline, not a grid. Depth comes from the stops, not a separate key: the walk pauses at *both* the "child of this task" slot and the "sibling" slot (indentation shows which), so you nest or stay level by stepping vertically. Single-line input frees Up/Down (no line navigation; `preventDefault` so the cursor doesn't jump); the form visibly relocates to the target and the typed title rides along.

### Membership (M4 or later)
- **Admin role.** A delegated tier between owner and editor: manage the roster (add / remove members, change roles below admin) without ownership — no initiative delete, no ownership transfer. Lets owners hand off member management; pairs with invite-by-email below. When this lands, ownership transfer demotes the old owner to **admin** instead of today's editor.
- **Taskmaster — a task-scoped full-control role.** Like viewer+ (m02.05 item 12.6) but stronger: full editor-level control over the task they're the direct assignee of *and its whole subtree* — create / delete / move / reorder / rename / re-staff within it — without any rights to the rest of the Initiative. The natural step up from viewer+ (which only grants progress / comments + pool-limited staffing) for someone you want to fully own a branch. The Initiative's second task-scoped permission.
- **Invite-by-email for non-users.** Adding a member by an email that matches no account prompts to send an invitation instead. The pending add is tracked; if and when that person creates an account, they're added to the initiative automatically. Pending invitees show as **pending** in the member list and can be removed while still pending (cancels the tracked add, so they're not joined if no longer needed).
- **Invites + pending assignment (notifications-first).** Turn "add a member" into an *invite* — a pending membership that can already hold task assignments before it's accepted, so assigning isn't blocked on acceptance. Tasks assigned to a not-yet-accepted member show the assignee pill **dimmed, with a dashed/dotted border** until they join. An invite is accepted by whichever account the recipient picks — e.g. invited at a work email, accepted with a personal account — so it binds to a person, not a fixed account. Shippable for **existing** users via in-app notifications ahead of the mailer; email-addressed invites to non-users stay gated on it (see *Email infrastructure* and *Invite-by-email for non-users* above).

### Comments & presence
- **Live chat for concurrent viewers.** A lightweight chat in the lower-left for everyone currently viewing an Initiative — so live back-and-forth has its own home and the per-task comment threads don't get co-opted as a chat. Presence-scoped to current viewers, ephemeral. (Pairs with making comments live, m02.06 item 14.3.)
- **Editable comments + edit history** (likely a later arc). Let a comment's author edit it, with a minimal edit-history popup surfacing prior versions.
- **Deletable comments with a tombstone** (likely a later arc). Let a comment be deleted but leave a placeholder note in its place (a "comment deleted" tombstone), so the thread's shape and any references survive.

### Templates (likely its own milestone)
- **Initiative templates.** Pre-built task trees that instantiate into a fresh Initiative — decomposition as a starting point, and a fix for the blank-canvas problem on first use. Three layers at very different sizes, worth keeping separable: (1) **curated / built-in** starter templates shipped with the app ("New Initiative from template") — smallest, highest onboarding payoff, could ship alone; (2) **save-as-template** — turn one of your Initiatives (or a subtree) into a personal reusable template; (3) **sharing / library** — give a template to another user or publish it (the big one: discovery, attribution, permissions, moderation — realistically its own milestone). A template captures the tree **skeleton** (titles, nesting, optionally priorities / sort modes / progress-calc) and instantiates **fresh** — no assignments, progress, members, activity, or co-assignees carried over. Shares machinery with "Duplicate a non-owned initiative" above (both copy a tree into a new owned Initiative).
