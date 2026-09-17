// What the primary nav is, in one place (m04.01 items 4.1, 4.4).
//
// The header and the narrow hamburger both render the SAME list from here, so
// they cannot drift into two slightly different products.
// Which entry is current is a question about the route, not about the URL
// string, so it is answered once and unit-tested.

import type { Route } from "../router/route.ts";

export type NavKey = "initiatives" | "assigned";

export interface NavItem {
  readonly key: NavKey;
  /** An absolute in-app path. */
  readonly to: string;
  /** Always rendered as text — no icon-only nav (spec §10). */
  readonly label: string;
}

export const NAV_ITEMS: readonly NavItem[] = [
  { key: "initiatives", to: "/app/initiatives", label: "Initiatives" },
  { key: "assigned", to: "/app/assigned", label: "Assigned to Me" },
];

/**
 * The nav entry the current route belongs to, or `null` when the route is
 * outside the nav (Account — reached from the avatar menu, not the nav —
 * not-found, or the `/app` redirect still in flight).
 *
 * One Initiative belongs under Initiatives: a user who has drilled in has not
 * left that section, and the nav saying otherwise would be a lie.
 */
export function activeNavKey(route: Route): NavKey | null {
  switch (route.kind) {
    case "initiatives":
    case "initiative":
      return "initiatives";
    case "assigned":
      return "assigned";
    default:
      return null;
  }
}

/** True when `key` is the entry to mark `aria-current="page"`. */
export function isCurrentNav(route: Route, key: NavKey): boolean {
  return activeNavKey(route) === key;
}
