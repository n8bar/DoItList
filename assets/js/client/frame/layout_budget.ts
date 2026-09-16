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
export const ASYNC_REGIONS = ["initiatives-list", "initiative-header"] as const;

export type AsyncRegion = (typeof ASYNC_REGIONS)[number];

export interface Reservation {
  /** Rows of skeleton drawn while the data is in flight. */
  readonly rows: number;
  /** The height of one row, in px — the typical height of the real thing. */
  readonly rowHeight: number;
  /** What assistive tech hears while the region is busy. */
  readonly label: string;
}

const BUDGET: Record<AsyncRegion, Reservation> = {
  // A row is a name line plus the progress bar under it, matching the real row
  // in `InitiativesScreen`.
  "initiatives-list": { rows: 6, rowHeight: 56, label: "Loading…" },
  // The heading, the subtitle line and the progress line, stacked.
  "initiative-header": { rows: 1, rowHeight: 80, label: "Loading…" },
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
