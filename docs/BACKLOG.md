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
- **Email infrastructure.** A mailer plus everything gated on it: email verification on change/registration, email-based password reset (account recovery ships mailer-free in `m02.04`), and the invite-by-email flow below.

### User preferences
- **Persist Initiative-list sort server-side.** The Initiatives index sort (mode + reverse + manual drag order) ships in localStorage (per-browser) in M02 Arc 3 worklist 6. When user profile/preferences gets built, move it to proper per-user server storage so it follows the user across devices. Manual order would land on `initiative_members.sort_order` (per-membership); the mode/reverse on a user-preferences record.

### Task row polish
- **Color-coded priority pills.** Map each priority (`high` / `low` / etc.) to its own chip color instead of the current monochrome zinc, so priority reads at a glance. Default (`normal`) stays the empty dashed placeholder. One-spot change in `task_node/1`'s priority chip.

### Membership (M4 or later)
- **Invite-by-email for non-users.** Adding a member by an email that matches no account prompts to send an invitation instead. The pending add is tracked; if and when that person creates an account, they're added to the initiative automatically. Pending invitees show as **pending** in the member list and can be removed while still pending (cancels the tracked add, so they're not joined if no longer needed).
