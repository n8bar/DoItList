// Who is using the right-hand pane (m04.01 item 4.1, fix round 1).
//
// The pane column exists only while a route is actually filling it — an empty
// slot is no slot, not an empty gutter. That is a counting problem, and counting
// is where this sort of thing goes wrong: a tenant that releases twice (React
// StrictMode double-invokes effects, and so does a remount under a transition)
// must not close a column another tenant is still using, and the count must
// never go negative and strand the column open.
//
// So the arithmetic lives here, pure and tested, and `pane.tsx` is only the
// wiring.

/** One more tenant. */
export function addTenant(count: number): number {
  return count + 1;
}

/** One fewer tenant, never below zero. */
export function removeTenant(count: number): number {
  return count > 0 ? count - 1 : 0;
}

/** The frame mounts the pane column only while somebody is in it. */
export function paneVisible(count: number): boolean {
  return count > 0;
}
