// Every navigation action looks like a control (m04.01 item 4.4, spec §10).
//
// One place decides what a nav control looks like in each of its states, so the
// header link, the rail link, the hamburger item, the theme toggle and Sign out
// cannot end up with five different ideas of "pressed". Returning a class
// string (rather than each component assembling its own) is what makes the
// state rules testable without a DOM.
//
// Every state has a VISIBLE boundary in both themes — border and fill, never
// colour alone — and the focus ring is `focus-visible` so pointer users don't
// get a ring they didn't ask for. Motion is `motion-reduce:`-guarded
// (UX_GUARDRAILS §1).

export interface ControlStateOptions {
  /** The route this control points at is the one showing. */
  readonly current?: boolean;
  /** A disclosure whose menu is open (`aria-expanded="true"`). */
  readonly open?: boolean;
  /** Present but not actionable. Reduced contrast, no pointer. */
  readonly disabled?: boolean;
  /** Fill the width and left-align — the rail and menu shape. */
  readonly block?: boolean;
  /** Fill the width and stack its content — the list-row shape. */
  readonly stack?: boolean;
}

/**
 * Shared by every state. `min-h-11` is the 44px touch target (UX_GUARDRAILS
 * §5); it relaxes to a denser 36px only from `sm:` up, where a pointer is the
 * likely input.
 */
export const CONTROL_BASE = [
  "inline-flex min-h-11 items-center gap-2 rounded-lg border px-3 py-1.5 text-sm font-medium",
  "transition-colors motion-reduce:transition-none",
  "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-emerald-600",
  "focus-visible:ring-offset-2 focus-visible:ring-offset-white",
  "dark:focus-visible:ring-emerald-400 dark:focus-visible:ring-offset-zinc-900",
  "sm:min-h-9",
].join(" ");

const DEFAULT_STATE = [
  "border-zinc-300 bg-white text-zinc-700",
  "hover:bg-zinc-100 hover:text-zinc-900 active:bg-zinc-200",
  "dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-200",
  "dark:hover:bg-zinc-800 dark:hover:text-zinc-50 dark:active:bg-zinc-700",
].join(" ");

/** The route you are on. Emerald is the product's "this one" colour. */
const CURRENT_STATE = [
  "border-emerald-600 bg-emerald-50 text-emerald-900",
  "hover:bg-emerald-100 active:bg-emerald-200",
  "dark:border-emerald-500 dark:bg-emerald-900/40 dark:text-emerald-100",
  "dark:hover:bg-emerald-900/60 dark:active:bg-emerald-900/80",
].join(" ");

/** A disclosure holding its menu open: pressed-in, distinct from current. */
const OPEN_STATE = [
  "border-zinc-400 bg-zinc-200 text-zinc-900 active:bg-zinc-300",
  "dark:border-zinc-500 dark:bg-zinc-700 dark:text-zinc-50 dark:active:bg-zinc-600",
].join(" ");

const DISABLED_STATE = [
  "pointer-events-none cursor-not-allowed",
  "border-zinc-200 bg-zinc-50 text-zinc-400",
  "dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-600",
].join(" ");

const BLOCK = "w-full justify-start";
const STACK = "w-full flex-col items-stretch justify-center gap-1 text-left";
const INLINE = "justify-center";

/**
 * The classes for one nav control. States are exclusive and ranked: disabled
 * beats everything (an unavailable control must never read as the active one),
 * then current, then open.
 */
export function controlClass(options: ControlStateOptions = {}): string {
  const state = options.disabled === true
    ? DISABLED_STATE
    : options.current === true
      ? CURRENT_STATE
      : options.open === true
        ? OPEN_STATE
        : DEFAULT_STATE;

  const shape = options.stack === true ? STACK : options.block === true ? BLOCK : INLINE;

  return [CONTROL_BASE, state, shape].join(" ");
}

/**
 * The three kinds of ACTION button (item 4.2): the ordinary one, the one that
 * carries the form or the dialog, and the one that destroys something.
 *
 * Same base as a nav control — same height, same touch target, same focus ring
 * — so a dialog's buttons and the header's buttons are visibly the same family.
 * The primary is the LiveView's solid emerald CTA (`core_components.button/1`),
 * not a second idea of what a primary button looks like.
 */
export type ActionVariant = "default" | "primary" | "danger";

export interface ActionOptions {
  readonly variant?: ActionVariant;
  /** In flight or otherwise unavailable. Never reads as the CTA. */
  readonly disabled?: boolean;
  readonly block?: boolean;
}

const PRIMARY_STATE = [
  "border-emerald-600 bg-emerald-600 text-white",
  "hover:bg-emerald-700 hover:border-emerald-700 active:bg-emerald-800",
  "dark:border-emerald-500 dark:bg-emerald-600 dark:hover:bg-emerald-500 dark:active:bg-emerald-700",
].join(" ");

const DANGER_STATE = [
  "border-red-600 bg-red-600 text-white",
  "hover:bg-red-700 hover:border-red-700 active:bg-red-800",
  "dark:border-red-500 dark:bg-red-600 dark:hover:bg-red-500 dark:active:bg-red-700",
].join(" ");

export function actionClass(options: ActionOptions = {}): string {
  if (options.disabled === true) {
    return controlClass({ disabled: true, ...(options.block === true ? { block: true } : {}) });
  }

  const state =
    options.variant === "primary"
      ? PRIMARY_STATE
      : options.variant === "danger"
        ? DANGER_STATE
        : DEFAULT_STATE;

  return [CONTROL_BASE, state, options.block === true ? BLOCK : INLINE].join(" ");
}
