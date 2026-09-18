// The unit-count badge (m03.04 6.5, m04.02 7.8.6–7.8.7): the roll-up's
// denominator with the glyph that names the mode, a small "s" when the count
// is not 1, and — on a top-level branch and on the Initiative header — the
// completed count stacked above the total. One component for the rows and the
// header (7.10.2), so the two never drift.

import type { ProgressCalc } from "../api/types.ts";
import { BotanicalIcon } from "./botanical.tsx";
import { badgeIcon, badgeIconClass, branchUnitTitle } from "./row_model.ts";

export interface UnitBadgeProps {
  calc: ProgressCalc;
  total: number;
  /** Given, the completed count stacks above the total when it is partial. */
  done?: number;
  id?: string;
  /** The element id of the stacked done count; rows use `data-done-count` instead. */
  doneId?: string;
  /** Placement classes, on top of the badge's own look. */
  className?: string;
}

export function UnitBadge({ calc, total, done, id, doneId, className }: UnitBadgeProps) {
  return (
    <span
      id={id}
      data-unit-count
      title={branchUnitTitle(calc)}
      className={[
        "inline-flex items-center gap-0.5 text-sm font-bold tabular-nums text-emerald-400",
        className ?? "",
      ]
        .filter((part) => part !== "")
        .join(" ")}
    >
      <BotanicalIcon kind={badgeIcon(calc)} className={badgeIconClass(calc)} />
      {total !== 1 && (
        <span data-unit-plural className="-ml-0.5 text-[1.2em] font-normal leading-none">
          s
        </span>
      )}
      {done === undefined ? (
        total
      ) : (
        <span className="inline-flex flex-col items-center leading-none">
          {done > 0 && done < total && (
            <span
              id={doneId}
              {...(doneId === undefined ? { "data-done-count": "" } : {})}
              className="text-[0.7em] opacity-50"
            >
              {done}
            </span>
          )}
          <span>{total}</span>
        </span>
      )}
    </span>
  );
}
