// A menu's keyboard behaviour, as arithmetic (item 4.2).
//
// The menu's open/close rules — including who gets focus back — are already
// `frame/menu_state.ts`, and this does not duplicate them. What is here is the
// other half: where the arrow keys go once the menu is open.
//
// The rules a pointer user never notices and a keyboard user lives by: Down and
// Up wrap, Home and End go to the ends, an item that cannot be used is stepped
// over rather than focused, and anything else is left to the browser so Tab
// still means Tab.

export interface MenuItemModel {
  readonly id: string;
  /** What the user reads. Never empty — this is the item's accessible name. */
  readonly label: string;
  /** Present but not actionable. Keeps its place in the list; focus skips it. */
  readonly disabled?: boolean;
  /** Destructive. The component gives it the danger style AND a confirm. */
  readonly danger?: boolean;
  /**
   * An in-app path. The item is then a real link — status bar, middle-click and
   * "open in new tab" all work — routed by the client's own router.
   */
  readonly href?: string;
  /**
   * The user has not seen this one yet (a notification). Drawn heavier and with
   * a marker, so "new" is never colour alone.
   */
  readonly unseen?: boolean;
}

const usable = (item: MenuItemModel): boolean => item.disabled !== true;

/** The first item the user can actually use, or `null` if there is none. */
export function firstEnabled(items: readonly MenuItemModel[]): number | null {
  const index = items.findIndex(usable);
  return index === -1 ? null : index;
}

/** The last usable item, or `null`. */
export function lastEnabled(items: readonly MenuItemModel[]): number | null {
  for (let index = items.length - 1; index >= 0; index -= 1) {
    if (usable(items[index] as MenuItemModel)) return index;
  }
  return null;
}

function step(items: readonly MenuItemModel[], from: number, delta: number): number | null {
  const count = items.length;
  if (count === 0) return null;
  // `from` may be -1 ("focus is on the trigger, nowhere in the list yet"), so
  // the start is normalised into range before stepping.
  let index = ((from % count) + count) % count;
  for (let taken = 0; taken < count; taken += 1) {
    index = (index + delta + count) % count;
    if (usable(items[index] as MenuItemModel)) return index;
  }
  return null;
}

/**
 * Where focus goes for `key`, or `null` when this menu has no opinion about
 * the key (the browser keeps it) or when no item can take focus.
 */
export function nextFocusIndex(
  items: readonly MenuItemModel[],
  current: number,
  key: string,
): number | null {
  switch (key) {
    case "ArrowDown":
      return step(items, current < 0 ? -1 : current, 1);
    case "ArrowUp":
      return step(items, current < 0 ? 0 : current, -1);
    case "Home":
      return firstEnabled(items);
    case "End":
      return lastEnabled(items);
    default:
      return null;
  }
}

export function menuItemDomId(menuId: string, itemId: string): string {
  return `${menuId}-item-${itemId}`;
}
