# BACKLOG
_Last updated: 2026-06-05_

Work for releases _after_ the upcoming one. The currently-targeted release and its milestones live in [`PLAN.md`](PLAN.md); this file is for everything beyond that.

## Conventions
1. Items here are noted but not yet scoped or scheduled.
2. Promotion to a milestone is the moment of commitment — at that point the item moves to PLAN.md's milestone table and gets a milestone doc under `docs/milestones/`.
3. Don't catalog implementation detail here; one or two lines per item is enough. Scope and acceptance criteria belong in the milestone doc, not in BACKLOG.

## Items

### Initiative lifecycle (M4 or later)
- **Trash — owner-only soft-delete.** Delete routes to a recoverable Trash first; permanent deletion from Trash stays owner-only (today's hard delete becomes that final step). Global — a trashed initiative leaves every member's dashboard. Manual purge only for now (auto-purge TBD).
- **Hidden — per-member.** Any member can hide an initiative from their own dashboard without touching anyone else's; restorable. Separate mechanism from Trash.
- **Leave an initiative.** Drop your own membership entirely — distinct from Hidden.
- **Duplicate a non-owned initiative.** Copy it into a brand-new initiative you own — new tasks, fresh timestamps, _not_ a clone of the original's history. Owners can disable duplication per-initiative, but it's a soft barrier only (manual recreation is always possible; make owners aware).
- **Trash ↔ duplicate interplay.** An owner-trashed initiative shows to its members as an unowned item in their Trash; unless the owner disabled duplication, they can duplicate it before it's permanently purged.

### Membership (M4 or later)
- **Invite-by-email for non-users.** Adding a member by an email that matches no account prompts to send an invitation instead. The pending add is tracked; if and when that person creates an account, they're added to the initiative automatically. Pending invitees show as **pending** in the member list and can be removed while still pending (cancels the tracked add, so they're not joined if no longer needed).
