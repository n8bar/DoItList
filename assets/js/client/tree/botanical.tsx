// The botanical icon set, drawn (m04.02 item 2.1.1).
//
// A port of `DoItWeb.CoreComponents.botanical_icon/1`, path for path: a tree on
// a top-level task, a branch on a parent, a leaf on a childless one. The
// metaphor is reserved in `docs/ProductSpec.md` § Visual Metaphor, and the
// client's tree has to carry the same one the LiveView's does — the same glyph,
// at the same weight, not an approximation of it.
//
// Decoration on top of a row that names itself in words, so always aria-hidden
// (guardrails §4.1).

import type { BotanicalKind } from "./row_model.ts";

export interface BotanicalIconProps {
  kind: BotanicalKind;
  className?: string;
}

const STROKE = {
  fill: "none",
  stroke: "currentColor",
  strokeLinecap: "round",
  strokeLinejoin: "round",
} as const;

export function BotanicalIcon({ kind, className }: BotanicalIconProps) {
  const shared = {
    className: className ?? "w-4 h-4",
    xmlns: "http://www.w3.org/2000/svg",
    viewBox: "0 0 24 24",
    "aria-hidden": true,
    ...STROKE,
  } as const;

  if (kind === "grove") {
    return (
      <svg {...shared} strokeWidth={2}>
        <path d="M10 10v.2A3 3 0 0 1 8.9 16H5a3 3 0 0 1-1-5.8V10a3 3 0 0 1 6 0Z" />
        <path d="M7 16v6" />
        <path d="M13 19v3" />
        <path d="M12 19h8.3a1 1 0 0 0 .7-1.7L18 14h.3a1 1 0 0 0 .7-1.7L16 9h.2a1 1 0 0 0 .8-1.7L13 3l-1.4 1.5" />
      </svg>
    );
  }

  if (kind === "tree") {
    return (
      <svg {...shared} strokeWidth={2}>
        <path d="M8 19a4 4 0 0 1-2.24-7.32A3.5 3.5 0 0 1 9 6.03V6a3 3 0 1 1 6 0v.04a3.5 3.5 0 0 1 3.24 5.65A4 4 0 0 1 16 19Z" />
        <path d="M12 19v3" />
      </svg>
    );
  }

  if (kind === "branch") {
    return (
      <svg {...shared} strokeWidth={1.75}>
        <path d="M3 21 C 8 17, 13 12, 21 4" />
        <path d="M9 14 L 6 10.5" />
        <path d="M15 8 L 12 4.5" />
        <g className="text-emerald-600 dark:text-emerald-400" fill="currentColor" stroke="none">
          <ellipse cx="5.4" cy="10" rx="1.4" ry="2.4" transform="rotate(-35 5.4 10)" />
          <ellipse cx="11.4" cy="4" rx="1.4" ry="2.4" transform="rotate(-35 11.4 4)" />
          <ellipse cx="20.6" cy="3.4" rx="1.4" ry="2.4" transform="rotate(-35 20.6 3.4)" />
        </g>
      </svg>
    );
  }

  return (
    <svg {...shared} strokeWidth={2}>
      <path d="M11 20A7 7 0 0 1 9.8 6.1C15.5 5 17 4.48 19 2c1 2 2 4.18 2 8 0 5.5-4.78 10-10 10Z" />
      <path d="M2 21c0-3 1.85-5.36 5.08-6C9.5 14.52 12 13 13 12" />
    </svg>
  );
}

/**
 * The branch chevron's own glyph. Heroicons' micro chevron reads thin at this
 * size, so the LiveView draws a raw stroke it can weight directly; the client
 * draws the same one, and rotates it off `aria-expanded` exactly as app.css does.
 */
export function Chevron({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={3.5}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      className={
        className ??
        "w-5 h-5 transition-transform motion-reduce:transition-none group-aria-[expanded=false]:-rotate-90"
      }
    >
      <path d="M3 5.5 L8 10.5 L13 5.5" />
    </svg>
  );
}
