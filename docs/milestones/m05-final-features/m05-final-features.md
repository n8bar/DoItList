# M05-Final-Features
_Status: stub · Planned start: after M03 (API & MCP) · Target: TBD_

> Canonical product behavior, vocabulary, and the roll-up formula live in [`ProductSpec.md`](../../ProductSpec.md). Universal UX/a11y baseline lives in [`UX_GUARDRAILS.md`](../../UX_GUARDRAILS.md). This milestone doc owns M05 scope and acceptance criteria once it's scoped; per-arc detail will live in arc files linked below.

## Goal

Land the **last product features** before going public — the account, security, and monetization pieces that the private app has done without. After this milestone the product is **feature-complete** for launch; M06 is preparation and launch, not new functionality. (Admin role, taskmaster, and avatar upload are real features too, but they don't gate launch — they're M08, just after.)

## Status

Stub — to be expanded. Not yet scoped into arcs.

## Planned scope

- **Email infrastructure & invites.** A mailer plus everything gated on it: email verification on change/registration, email-based password reset, and the **invite system** — "add a member" becomes an *invite* (a pending membership that can already hold task assignments before acceptance; pending assignees show dimmed with a dashed border until they join). An invite reaches an existing account or an email with no matching account (auto-joining them if they later register), binds to whichever account accepts it, and shows as pending in the roster (removable). Invitees are notified in-app + by email. The foundation most of the rest leans on.
- **Recovery codes.** One-time codes (generated on the account page, shown once, hashed at rest) with a "use a recovery code" login path. The public-opening gate while admin resets won't scale.
- **TOTP two-factor.** Security, not recovery — pairs with recovery codes (or the live mailer) so 2FA lockouts have an exit.
- **GUIDs for Initiative ids.** Replace the sequential integer Initiative id with a GUID in URLs and the API/MCP surface — sequential ids leak count/ordering and invite guessing once those surfaces are public; ids stay plumbing either way (agents resolve Initiatives by name). Must land before M06 opens the API/MCP.
- **Task Trash (Initiative-level) with 30-day hard delete.** A real trash view for soft-deleted tasks — browse and restore them beyond the undo stack — plus a retention sweep that hard-deletes at 30 days. Today a deleted task past the 500-event undo horizon is retained forever yet reachable by nothing. The sweep also owns the jsonb edges no FK can cascade: notification rows carry task/initiative ids inside `data`, so hard-deleting a task must prune those rows or leave them gracefully degraded (snapshot titles already render; the deep link falls back to the Initiative).
- **Donation screen.** A "support this project" page — suggested amounts + a payment-processor integration (Stripe or similar), linked from the nav / account menu. Brings a payment-processor dependency. (Only meaningful once there's a public audience, so it rides with the public-open work.)
- **Ephemeral chat, session-tied (buffer, presence, unread, read markers).** Chat stops clearing on page exit and ties to the login session instead: a server-side per-Initiative ring buffer (capped, in-memory only, never persisted) where each viewer sees the messages newer than their own session start — chat survives refresh, navigation, and a closed tab, and clears on logout. Accepted consequences: a server restart wipes chats, and the cap makes older backlog best-effort. The existing "Chat is live-only; messages clear when you leave." caption stays accurate and stays put. Web-only — no API/MCP exposure.
  - **Reachability presence.** The chat's "nobody else here" state keys off app-wide presence of the Initiative's *members* (a non-member being online doesn't count), and its empty-state copy names that meaning. Member-avatar dots keep their current page-presence meaning.
  - **Unread dot + sound.** A red dot — never a count; it's not an inbox — on both Initiative list views when an Initiative has unread chat, and an incoming message on another Initiative plays the same sound as in-chat. No sound for one's own messages; suppressed for the chat currently viewed. Delivery via a per-user notification topic (send fans out to each member's topic) — stable under membership change, reusable later (M07 native notifications). The per-user last-read cursor lives server-side in the same ephemeral store.
  - **Read markers.** Opening the chat box marks the log read, and the cursor keeps advancing while it stays open — gated on tab visibility, so a background tab never reports "seen." Each online member (never oneself) shows a very small avatar at the last message they read, clamped to the top of the viewer's window when they've read none the viewer can see; same-position avatars cluster in a row capped at 9 with a +N overflow. Opening the chat clears that Initiative's red dot; cursor moves broadcast live to viewers.

## Optional

- **Task indexes — deferred extras.** Follow-ups to the fixed index styles from [`m02.07`](../m02-ux-buildout/m02.07-layout+task-tree-revisited.md) (item 1.7): **Custom Outline** (pick the glyph set per level), a **depth-flat variant** (`1.`, `2.` per level, no ancestor prefix), and a **continue-across-collapse** toggle. If deferred, it doesn't make the first release — and that's fine.
- **Multi-select tasks (batch edit + batch move).** Select several tasks at once — Ctrl-click toggles one in/out of the selection (add/subtract), Shift-click selects a range; tasks inside a collapsed branch are excluded. The Details pane starts blank and shows only the values shared by every selected task; editing a field applies to all selected tasks where applicable (branches skip progress, leaves skip sorting). Dragging a selected task's handle moves the whole selection as a batch. Bulk-undo semantics (one atom vs per event, parked in [`m02.06`](../m02-ux-buildout/m02.06-undo-redo.md)) get decided when this lands. **Optional in M05 only, not in the program:** if M05 doesn't take it, it gets slotted into a named later milestone at M05 close — deferral needs a destination, never the backlog.
  - **Batch move:** the move reduces to the selection-roots (the shallowest selected node of each subtree), each carrying its whole subtree — a selected descendant under a selected ancestor is subsumed (no orphans), so a Shift-range may span a parent and its visible children with no pre-collapse step. Per-drop constraints: no cycle (the drop target can't sit inside any selected subtree); a reorder (edge-band drop) needs the roots to share one parent, otherwise only reparent/promote applies. Landing in a new parent follows that parent's sort mode — auto-sort places/interleaves the incoming roots per its rule; manual lands them contiguously at the drop position in their relative order.

## Preconditions

- M02 (UX Buildout) lands — membership, roster, and account surfaces the invite/role work extends are stable.
- Email infrastructure is foundational here: invites, verification, and email password reset all gate on the mailer.

## Open Questions

- Mailer provider / transport (transactional email service vs self-hosted SMTP).
- Payment processor for the donation screen, and what compliance it pulls in.

## Non-Goals

_(TBD once scoped.)_

## Acceptance Criteria

_(TBD once scoped.)_

## Branch

`M05-final-features` (created at scoping time).
