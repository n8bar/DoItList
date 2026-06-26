# UX_GUARDRAILS
_Last updated: 2026-06-10_

Universal UX/a11y baseline. Apply on every UI change. This doc is universal principles only — project-specific standards live in [`ProductSpec.md`](ProductSpec.md).

Keep this doc tight. If the universal baseline grows past ~25 rules, it stops being read.

## Universal Baseline

### 1. Layout & motion
1.1 No layout shift after initial render. Reserve space for async/late content; never let arriving elements push earlier ones.
1.2 Respect `prefers-reduced-motion`. Decorative animation off by default for users who opt out.
1.3 Mobile-first sizing. Default to fluid layouts; explicit breakpoints, not fixed pixel widths.

### 2. Input & error handling
2.1 Preserve user input on validation errors. Forms re-render with submitted values; never make a user re-type.
2.2 Surface errors near their source — next to the field that caused them, not at the top of the form unless the error is page-level.
2.3 Error messages explain the cause and a path forward. Avoid "An error occurred"; say what happened and what to try.
2.4 Empty states tell the user what to do next. Never just an empty screen.

### 3. Focus & keyboard
3.1 Focus moves into a dialog when it opens and returns to the trigger when it closes. Never trap focus indefinitely.
3.2 Visible focus indicators always. Don't suppress outlines without providing a clear replacement.
3.3 Keyboard reachability: every interactive element must be operable by keyboard alone; tab order matches visual order.

### 4. Naming & contrast
4.1 Every interactive element has a discernible accessible name (visible label, `aria-label`, or `aria-labelledby`).
4.2 Text meets WCAG AA contrast (4.5:1 normal, 3:1 large). Verify before shipping.

### 5. Touch & sizing
5.1 Touch targets ≥ 44×44px on mobile/touch surfaces.
5.2 Layouts tolerate ~30% string growth without breaking — for translations and longer-than-expected content.

### 6. Loading & action feedback
6.1 Operations longer than ~100ms show progress immediately.
6.2 Optimistic UI for fast operations: reflect the action instantly when likely to succeed; reconcile on error.
6.3 Confirmations only for actions that are destructive, irreversible, or whose side effects reach beyond what the user is looking at (e.g., a move that silently flips an ancestor's completion). These cases warrant a confirm *even when the action is undoable*, and take precedence over 6.4. Never gate ordinary actions behind "are you sure?" — and surprise-scope confirmations must be suppressible.
6.4 Otherwise — for actions 6.3 doesn't name — prefer undo over confirm where feasible: let the user act, with a short window to reverse. Undo fits when the user sees the result and can choose to reverse it; a confirm (6.3) fits when the effect can land off-screen, since you can't undo a change you never noticed.
6.5 Interactions that only change view state — selection, expand/collapse, focus — never wait on the network. Opening a confirmation dialog counts when its content is already client-known.
6.6 Confirmations preserve optimism. A confirm that interrupts an optimistic action must not visually undo it while the user decides — Cancel reverts it, Proceed carries it through.
6.7 Acknowledge every action immediately. Every user-initiated action is acknowledged the instant it's initiated — applied optimistically when the client can complete it (6.2), shown in-flight when it's server-gated (6.1). A round-trip never delays *acknowledgement*; no action leaves the initiator wondering whether it registered.
6.8 Interactive from first paint. A painted page is a usable page — never "looks ready but isn't." Client-ownable interactions work before the connection is live; **every** action taken before connect — client-ownable or server-gated, and including affordances added later — is acknowledged at the moment of the action and reconciled on connect: never silently dropped, and never shown as succeeded when it wasn't. New server-gated affordances ride the dead-window capture path; they don't get to reintroduce the gap.
6.9 Any transport. The §6 guarantees hold on both WebSocket and the LongPoll fallback — never let the experience depend on the fast path.

### 7. Navigation & state
7.1 Same path = same content. Back button works as expected; refreshing a page returns the user where they were.
7.2 Don't override system color-scheme preference unless the user explicitly opted in.
7.3 State lives where its lifetime is. The client owns ephemeral UI state — selection, expand/collapse, focus, open panes, optimistic in-flight changes — and re-asserts it across every re-render and reconnect; the server owns durable data and sync (view-state changes never wait on the network, 6.5).
7.4 Presence continuity. Navigating within the app keeps the live session, its subscriptions, and the user's presence intact — no tear-down-and-rebuild per navigation that flickers the user out and back in for others.
