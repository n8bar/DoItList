# Resilient Client
_Last updated: 2026-09-14_

The client-runtime contract for Do It List. [`ProductSpec.md`](../ProductSpec.md) owns product behavior; [`UX_GUARDRAILS.md`](../UX_GUARDRAILS.md) owns the universal interaction baseline. This specification defines how a browser renders that behavior, submits work, collaborates live, recovers, and remains efficient.

## 1. Responsibility boundary

The browser owns rendering, route-level presentation, ephemeral view state, the local Initiative model, optimistic state, and the pending-write queue. The server owns identity, permissions, validation, canonical ordering, transactions, durable records, roll-up truth, and real-time publication.

Phoenix may serve a minimal bootstrap document, static assets, JSON data, and authenticated channels. Product content and interactive controls shall not depend on server-rendered DOM patches. Email and other non-browser output are outside this boundary.

Every client uses the same server-side operations. Transports differ. Authorization, validation, transactions, and rules do not. Presentation code never becomes a secondary implementation of product behavior.

## 2. Bootstrap and rendering

A painted interactive control shall work immediately. Route changes, selection, panes, menus, filters, focus, and expand/collapse are client-owned and never wait for the network. Server-gated actions acknowledge immediately with either an optimistic result or a visible in-flight state.

The client shall preserve the behavior defined by the Product Spec and satisfy the UX Guardrails across desktop and narrow layouts, pointer and touch input, keyboard use, both themes, and assistive technology. A failure to load or start the client produces an explicit recovery screen rather than inert product-shaped markup.

## 3. Operation lifecycle

Every durable user action has a stable client-generated idempotency key and one visible lifecycle:

1. Apply or acknowledge the intent locally.
2. Persist its operation and recovery data on the device.
3. Submit through the atomic operations surface.
4. Reconcile the canonical acknowledgement and broadcast in either arrival order.
5. Remove it from the queue only after the server outcome is known.

Transport failure or an unknown outcome retries the identical payload with the identical key. Validation and permission failures do not retry automatically. Structural actions revert to canonical state; editable user content remains recoverable as unsaved input until the user retries or discards it. No failure silently drops input.

Operations queued by one client replay in creation order. An atomic batch remains one queue entry and never partially replays.

## 4. Ordered live delivery

Every committed Initiative mutation produces one canonical delta envelope with the Initiative id, monotonic Initiative sequence, originating operation key when present, actor, and the changed or removed records needed to update a client without another database read.

Clients apply only the next sequence:

- a duplicate or older envelope is ignored;
- the next consecutive envelope is applied once;
- a gap makes the client obtain a fresh snapshot;
- an acknowledgement and its matching broadcast deduplicate regardless of arrival order.

Initial load and resynchronization subscribe before installing a snapshot. Deltas arriving during the snapshot read are buffered, then consecutive deltas newer than the snapshot sequence are applied. A gap restarts from a new snapshot. This closes the snapshot/broadcast race without retaining an unlimited event log.

## 5. Reconnect and convergence

The last-known Initiative snapshot and unacknowledged operations are account- and Initiative-scoped in IndexedDB, bounded by age and size, and purged on logout. This recovery cache is not a permanent offline database; a client with no trustworthy snapshot does not invent one.

On connection loss, the last-known interface stays readable and client-owned interactions keep working. Durable actions that can be expressed safely are queued and marked unsaved. Actions requiring fresh server-only facts remain available only with an immediate, explicit unavailable state.

Reconnection obtains canonical state, reconciles it with pending intent, replays the queue, and reaches the same state as every other authorized client. Reload and tab crash follow the same path from IndexedDB. Logout clears snapshots and pending work after warning about any unsaved operations.

Automatic reconnect uses bounded exponential backoff with jitter. After the retry budget, the client stops the active loop, states that it is offline, preserves work, and offers a clear Retry action. A low-frequency reachability probe may restore service without producing a visible reconnect loop.

## 6. Concurrent changes

Last committed writer wins, as required by the Product Spec. Field updates carry only fields the user changed. On a stale record, the client rebases that intent onto the current record and retries with the same user-visible meaning; a later accepted write is therefore the later writer. Independent fields do not erase one another.

Moves and reorders use stable Task and anchor ids and re-evaluate the same relative intent against the current tree. A deleted target, lost permission, cycle, or otherwise impossible intent is rejected visibly and restored to canonical placement. Automatic conflict retry is bounded; repeated contention pauses that operation for explicit retry rather than looping.

Canonical broadcasts always win over display-only predictions of roll-up progress. Activity and undo retain the product's existing recovery trail; there is no merge editor or lock.

## 7. Degraded and error states

Connection presentation distinguishes connecting, live, reconnecting, offline with pending work, offline without pending work, and an unrecoverable client error. It never relies on color alone. Pending state appears at the affected control or content as well as in the connection summary.

An authorization change takes effect live. Losing access removes cached Initiative data and stops replay. Slow or unavailable servers never turn already-rendered content into a frozen page.

## 8. Concurrent-user efficiency

The server performs validation and persistence once per operation, not once per viewer. A committed delta is serialized once and fanned out without a per-recipient tree render or database read. Idle connections cause no polling or database work. Snapshot work may scale with tree size, but an unchanged version should be reusable rather than rebuilt independently for simultaneous readers.

Per-connection and per-Initiative buffers are bounded. A slow client that falls behind is told to resnapshot; it cannot create unbounded server memory or delay healthy recipients. Presence and ephemeral chat follow the same bounded-fan-out discipline.

Capacity is judged on a resource-capped Docker reference environment. The published envelope includes many rooms, one hot room, an idle soak, burst writes, and a reconnect storm. Reports carry request and convergence latency distributions, errors, throughput, CPU, memory, database queries/connections/locks, and network volume. Scaling work optimizes measured bottlenecks; hardware increases do not substitute for a failing efficiency invariant.

## 9. Large Initiatives

The client stores Tasks in a normalized model and derives a flat visible-row projection from hierarchy plus filters. Collapsed and filtered descendants do not produce layout work. The DOM is windowed to visible rows with bounded overscan, while keyboard navigation, selection, focus, drag targets, accessible position information, and deep links continue to behave across unmounted rows.

An ordinary change updates the affected records, ancestry, ordering, references, and visible projection rather than rebuilding the whole tree. Server-authored roll-up truth remains authoritative. Explicit whole-tree actions may inspect the local model, but rendering work remains proportional to what is visible.

The reference large-Initiative fixtures cover at least 3,000 Tasks, deep nesting, wide sibling sets, long titles, mixed completion, references, assignees, and collapsed branches.

## 10. Tree and view controls

Navigation actions shall look like controls: visible button boundaries, text labels where meaning is not universal, and clear hover, focus, pressed, open, active-filter, and disabled states in both themes. Touch targets follow the universal baseline.

The Tree Tools menu provides Expand all, Collapse all, Collapse completed branches, Expand incomplete branches, Expand selected subtree, and Collapse selected subtree. These are local view actions and never make a network request.

The in-context View control exposes the existing personal row preferences for Priority, Assignee, Checkbox & progress bar, and Leaf / child count. Changes apply immediately and persist through the existing account preference. It also exposes:

- **Hide completed Tasks:** per-browser, per-Initiative view state. Its active state remains conspicuous wherever the filter can be turned off.
- **Descriptions below progress:** an Initiative setting shared by its members. When enabled, descriptions render beneath the progress bar; when disabled, the existing compact behavior remains.

Title and the affordance needed to reveal hidden content remain visible. View controls never change Progress, completion, permissions, or what contributes to roll-up.

## 11. Performance budgets and proof

Every action meets `UX_GUARDRAILS.md` §6; local acknowledgement must occur by the next paint and within its 100 ms threshold. Before optimization begins, the repository records:

- the capped reference hardware and software profile;
- baseline results from the retiring implementation;
- numeric budgets for local interaction, persistence, remote convergence, capacity, reconnect recovery, memory, and large-tree work;
- the fixture and command for each measurement;
- warm-up, sample count, percentiles, and known limits.

Budgets are fixed before optimization and cannot be relaxed without an explicit product decision and recorded reason. Automated regression tests cover deterministic invariants; repeatable load and browser benchmarks produce reports at defined regression checkpoints. Human checks judge comprehension, feedback, visual quality, and recovery confidence—not throughput by eye.

## 12. Security and privacy

The browser never stores an API bearer token. Browser reads, writes, and channels use the authenticated web session with the same server authorization as every other surface. Cached data is scoped to the signed-in account, purged on logout or access loss, and never exposed across accounts sharing a browser profile.

Operation payloads and broadcasts disclose only records the recipient may read. Client checks improve feedback but never replace server authorization or validation.
