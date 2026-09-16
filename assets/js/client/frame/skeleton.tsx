// The space a region holds open while its data is in flight (item 4.6).
//
// Not decoration: this is the layout budget made visible. The skeleton claims
// the height the real content will take, so the moment the data lands it fills
// space that was already there and nothing below it moves.
//
// It is honest about what it is — `aria-busy` plus a "Loading…" a screen reader
// hears — and never a product-shaped fake the user could mistake for content.

import type { AsyncRegion } from "./layout_budget.ts";
import { ROW_GAP, reservation, reservedHeight } from "./layout_budget.ts";

export function Skeleton({ region, id }: { region: AsyncRegion; id?: string }) {
  const { rows, rowHeight, label } = reservation(region);

  return (
    <div
      {...(id === undefined ? {} : { id })}
      role="status"
      aria-busy="true"
      data-region={region}
      className="mt-4"
      style={{ minHeight: reservedHeight(region) }}
    >
      <span className="sr-only">{label}</span>
      <div className="flex flex-col" style={{ gap: `${ROW_GAP}px` }}>
        {Array.from({ length: rows }, (_, index) => (
          <div
            key={index}
            aria-hidden="true"
            style={{ height: `${rowHeight}px` }}
            className="animate-pulse rounded-lg bg-zinc-100 motion-reduce:animate-none dark:bg-zinc-800"
          />
        ))}
      </div>
    </div>
  );
}
