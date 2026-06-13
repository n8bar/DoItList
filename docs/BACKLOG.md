# BACKLOG
_Last updated: 2026-06-05_

Work for releases _after_ the upcoming one. The currently-targeted release and its milestones live in [`PLAN.md`](PLAN.md); this file is for everything beyond that.

## Conventions
1. Items here are noted but not yet scoped or scheduled.
2. Promotion to a milestone is the moment of commitment — at that point the item moves to PLAN.md's milestone table and gets a milestone doc under `docs/milestones/`.
3. Don't catalog implementation detail here; one or two lines per item is enough. Scope and acceptance criteria belong in the milestone doc, not in BACKLOG.

## Items

### Initiative lifecycle (M4 or later)
- **Hidden — per-member.** Any member can hide an initiative from their own dashboard without touching anyone else's; restorable. Separate mechanism from Trash (promoted to `m02.06`).
- **Leave an initiative.** Drop your own membership entirely — distinct from Hidden.
- **Duplicate a non-owned initiative.** Copy it into a brand-new initiative you own — new tasks, fresh timestamps, _not_ a clone of the original's history. Owners can disable duplication per-initiative, but it's a soft barrier only (manual recreation is always possible; make owners aware).
- **Trash ↔ duplicate interplay.** An owner-trashed initiative (Trash ships in `m02.06`) shows to its members as an unowned item in their Trash; unless the owner disabled duplication, they can duplicate it before it's permanently purged.

### Account (M4 or later)
- **Avatar upload.** User-supplied avatar images replacing/augmenting the generated ones from `m02.04` — brings file storage, serving, size limits, image processing.
- **Email infrastructure.** A mailer plus everything gated on it: email verification on change/registration, email-based password reset, and the invite-by-email flow below. Until it exists, forgotten passwords are admin resets (fine at private scale).
- **Recovery codes — the public-opening gate.** One-time codes (generated on the account page, shown once, hashed at rest) with a "use a recovery code" login path. Required before opening to the public **if** the mailer isn't live by then; unnecessary while admin resets cover everyone.
- **TOTP two-factor.** Security, not recovery — pairs with recovery codes (or a live mailer) so 2FA lockouts have an exit.

### Task row polish
- **Color-coded priority pills.** Map each priority (`high` / `low` / etc.) to its own chip color instead of the current monochrome zinc, so priority reads at a glance. Default (`normal`) stays the empty dashed placeholder. One-spot change in `task_node/1`'s priority chip.

### Membership (M4 or later)
- **Admin role.** A delegated tier between owner and editor: manage the roster (add / remove members, change roles below admin) without ownership — no initiative delete, no ownership transfer. Lets owners hand off member management; pairs with invite-by-email below. When this lands, ownership transfer demotes the old owner to **admin** instead of today's editor.
- **Invite-by-email for non-users.** Adding a member by an email that matches no account prompts to send an invitation instead. The pending add is tracked; if and when that person creates an account, they're added to the initiative automatically. Pending invitees show as **pending** in the member list and can be removed while still pending (cancels the tracked add, so they're not joined if no longer needed).
