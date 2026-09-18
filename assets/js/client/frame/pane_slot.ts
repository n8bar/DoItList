// Who is using the right-hand pane (m04.01 item 4.1, fix round 1; m04.02 item 2.3).
//
// The pane column exists only while a route is actually filling it — an empty
// slot is no slot, not an empty gutter. That is a counting problem, and counting
// is where this sort of thing goes wrong: a tenant that releases twice (React
// StrictMode double-invokes effects, and so does a remount under a transition)
// must not close a column another tenant is still using, and the count must
// never go negative and strand the column open.
//
// Each tenant also leaves the frame a way to close it (item 2.3.2): below `lg:`
// the pane is the workspace's flyout, and the flyout's own X and backdrop are
// the frame's controls, not the tenant's. The frame knows nothing about what
// closing means — for the Details pane it is a deselect — it only calls.
//
// So the arithmetic lives here, pure and tested, and `pane.tsx` is only the
// wiring.

/** What a tenant does when the frame's close control fires. */
export type CloseTenant = () => void;

/** The tenants, in the order they arrived. */
export type Tenants = readonly CloseTenant[];

export const NO_TENANTS: Tenants = [];

/** One more tenant. */
export function addTenant(tenants: Tenants, close: CloseTenant): Tenants {
  return [...tenants, close];
}

/** One fewer tenant: exactly one instance of `close`, and a stranger is a no-op. */
export function removeTenant(tenants: Tenants, close: CloseTenant): Tenants {
  const at = tenants.lastIndexOf(close);
  if (at < 0) return tenants;
  return [...tenants.slice(0, at), ...tenants.slice(at + 1)];
}

/** The frame mounts the pane column only while somebody is in it. */
export function paneVisible(tenants: Tenants): boolean {
  return tenants.length > 0;
}

/**
 * The flyout's `data-open` marker, exactly as the workspace renders it:
 * `"true"` while open, absent otherwise.
 */
export function paneOpenMarker(tenants: Tenants): "true" | undefined {
  return paneVisible(tenants) ? "true" : undefined;
}

/** The flyout's Close (its X or the backdrop): every tenant closes, each once. */
export function closeTenants(tenants: Tenants): void {
  for (const close of new Set(tenants)) close();
}
