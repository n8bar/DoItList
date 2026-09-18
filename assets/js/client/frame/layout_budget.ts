// Reserved space for content that has not arrived yet (m04.01 item 4.6).
//
// The rule: nothing already on the glass moves when data lands. A spinner that
// is one line tall and is replaced by a six-row list moves everything under it,
// and on a slow link the user watches the page jump twice. So every async
// region declares, up front, how much room it will take — the skeleton claims
// exactly that, and the real content lands inside the space already held open.
//
// This module is the declaration. `layout_budget.test.ts` holds the line that
// every async region in the client has one; the frame and the screens read the
// numbers from here rather than sprinkling their own magic heights.

/** Every region of the client that paints before its data exists. */
export const ASYNC_REGIONS = ["initiatives-list", "initiative-header", "initiative-tree"] as const;

export type AsyncRegion = (typeof ASYNC_REGIONS)[number];

export interface Reservation {
  /** Rows of skeleton drawn while the data is in flight. */
  readonly rows: number;
  /** The height of one row, in px — the typical height of the real thing. */
  readonly rowHeight: number;
  /** What assistive tech hears while the region is busy. */
  readonly label: string;
}

/**
 * The height of one Initiatives card, in px. THE source of truth: the skeleton
 * row and the real card both render exactly this, so a skeleton row and the
 * card that replaces it are the same size and the list cannot collapse when the
 * data lands (item 4.6). Change it here or not at all.
 *
 * The M02 card (m04.02 item 4.3): 16px padding top and bottom, the name line
 * with its badge, and the 16px progress bar 8px under it.
 */
export const LIST_ROW_HEIGHT = 80;

/**
 * The height of one task row, in px. A title line, a second line for the
 * description or the wrap, and the progress bar pinned to the bottom edge.
 */
export const TREE_ROW_HEIGHT = 72;

const BUDGET: Record<AsyncRegion, Reservation> = {
  // A card is a name line plus the progress bar under it, matching the real
  // card in `InitiativesScreen` — which renders `LIST_ROW_HEIGHT` too.
  "initiatives-list": { rows: 6, rowHeight: LIST_ROW_HEIGHT, label: "Loading…" },
  // The title row, the subtitle line and the roll-up bar, stacked.
  "initiative-header": { rows: 1, rowHeight: 80, label: "Loading…" },
  // The tree under the header. A task row is a two-line row plus its progress
  // bar; six of them is a screenful, so the first paint holds open roughly what
  // the tree will fill and the page does not jump when the read lands.
  "initiative-tree": { rows: 6, rowHeight: TREE_ROW_HEIGHT, label: "Loading…" },
};

/** The space `region` holds open. Total, in px, including the row gaps. */
export function reservation(region: AsyncRegion): Reservation {
  return BUDGET[region];
}

/** Gap between skeleton rows, in px. Matches the real list's row spacing. */
export const ROW_GAP = 8;

/** The `min-height` a region reserves, as a CSS length. */
export function reservedHeight(region: AsyncRegion): string {
  const { rows, rowHeight } = reservation(region);
  return `${rows * rowHeight + (rows - 1) * ROW_GAP}px`;
}

/**
 * The width a numeric badge holds open, so a count or a percentage arriving
 * cannot shove its neighbours sideways. `ch` units, because the content is
 * digits rendered with `tabular-nums`.
 */
export const COUNT_MIN_WIDTH = "4ch";
