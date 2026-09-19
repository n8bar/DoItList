// What the user is told about the connection (item 4.3, spec §7; m04.03 5.1).
//
// Six states, and the words for each, decided here — in a module a unit test
// can walk end to end — rather than in a component that happens to be on
// screen. Spec §7 requires all six to be *distinguished*, and never by colour
// alone, so each one carries its own text label and its own icon; the tone is
// the third cue, not the only one.
//
// `degradedState` is the ONE derivation (m04.03 5.1.2): the summary, the
// offline banner and every control that greys itself out offline read the
// same answer, so they can never disagree about whether we are offline.
//
// Pending work appears in the label as a readable count, not as a dot: "three
// changes waiting" is a fact the user can act on, a coloured dot is a riddle.

import type { ConnectionStatus, StorageHealth } from "../state/recovery.ts";
import type { IconName } from "./icons.ts";

/**
 * The degraded-mode states (spec §7). `offline-idle` is offline with nothing
 * waiting; `offline-pending` is offline with unsent or parked work on the
 * device; `error` is the unrecoverable one — the client itself cannot go on
 * and a reload is the way out.
 */
export type SummaryState =
  | "connecting"
  | "live"
  | "reconnecting"
  | "offline-pending"
  | "offline-idle"
  | "error";

/** The same six, under the arc's name for them (m04.03 5.1.2). */
export type DegradedState = SummaryState;

/** The six, in the order spec §7 lists them. */
export const SUMMARY_STATES: readonly SummaryState[] = [
  "connecting",
  "live",
  "reconnecting",
  "offline-pending",
  "offline-idle",
  "error",
];

/** Which control, if any, the summary offers alongside the words. */
export type SummaryAction = "retry" | "reload" | null;

export type SummaryTone = "busy" | "live" | "warn" | "danger";

export interface ConnectionDescription {
  readonly state: SummaryState;
  /** The visible text. Never empty: the text IS the signal. */
  readonly label: string;
  /** A second line, when the state needs explaining. */
  readonly detail: string | null;
  readonly icon: IconName;
  readonly tone: SummaryTone;
  readonly action: SummaryAction;
  /** Shown to assistive tech but visually understated (the live state). */
  readonly quiet: boolean;
  /** The icon turns only while something really is in flight. */
  readonly spin: boolean;
}

export interface ConnectionInput {
  readonly connection: ConnectionStatus;
  /** Writes made but not yet acknowledged. */
  readonly pendingCount: number;
  /** An unrecoverable client error, or `null`. */
  readonly fatal: string | null;
}

/**
 * The one place that decides which state we are in. A broken client beats
 * everything — telling somebody we are "live" while the tab is wedged would be
 * the worst of the six lies available.
 */
export function degradedState(input: ConnectionInput): DegradedState {
  if (input.fatal !== null) return "error";
  if (input.connection !== "offline") return input.connection;
  return input.pendingCount > 0 ? "offline-pending" : "offline-idle";
}

/** `degradedState`, under the summary's older name. */
export const summaryState = degradedState;

/**
 * Has the client stopped trying on its own? True in both offline states —
 * the ones where a server-gated control cannot be queued (m04.03 5.3) and
 * where the banner offers Retry. Not while reconnecting: a control that
 * greyed out on every blip would flicker through every retry.
 */
export function isOfflineState(state: DegradedState): boolean {
  return state === "offline-idle" || state === "offline-pending";
}

/** The one-line banner over the tree in the offline states (m04.03 5.1.3). */
export const OFFLINE_BANNER = "Offline — changes are kept on this device and sent when you’re back.";

const changes = (count: number): string => `${count} ${count === 1 ? "change" : "changes"}`;

export function describeConnection(
  state: SummaryState,
  pendingCount = 0,
): ConnectionDescription {
  switch (state) {
    case "connecting":
      return {
        state,
        label: "Connecting…",
        detail: null,
        icon: "arrow-path",
        tone: "busy",
        action: null,
        quiet: false,
        spin: true,
      };
    case "live":
      return {
        state,
        label: "Live",
        detail: null,
        icon: "bolt",
        tone: "live",
        action: null,
        // Nothing is wrong, so nothing shouts — but a screen-reader user is
        // entitled to know the page is current, so it is still here.
        quiet: true,
        spin: false,
      };
    case "reconnecting":
      return {
        state,
        label: "Reconnecting…",
        detail: "Your changes are kept on this device until it comes back.",
        icon: "arrow-path",
        tone: "busy",
        action: null,
        quiet: false,
        spin: true,
      };
    case "offline-pending":
      return {
        state,
        label: `Offline — ${changes(pendingCount)} waiting`,
        detail: "Nothing is lost. Try again when you have a connection.",
        icon: "signal-slash",
        tone: "warn",
        action: "retry",
        quiet: false,
        spin: false,
      };
    case "offline-idle":
      return {
        state,
        label: "Offline",
        detail: "Showing what this device already has.",
        icon: "signal-slash",
        tone: "warn",
        action: "retry",
        quiet: false,
        spin: false,
      };
    case "error":
      return {
        state,
        label: "Do It List hit a problem",
        detail: "Reload to pick up where you left off.",
        icon: "exclamation-triangle",
        tone: "danger",
        action: "reload",
        quiet: false,
        spin: false,
      };
  }
}

/**
 * The local-copy line under the summary: what a degraded or missing cache means
 * for the user, in the user's terms. `null` when there is nothing to say.
 *
 * A browser with no store and work waiting is the one case where a reload
 * costs something (m04.03 5.1.2): the queue lives in memory alone, so the
 * line says so plainly instead of the general "a reload starts from the
 * server" — which would read as harmless.
 */
export function storageLine(health: StorageHealth, note: string | null, pendingCount = 0): string | null {
  if (health === "opening" || health === "ready") return null;

  const headline =
    health === "unavailable"
      ? pendingCount > 0
        ? `This browser isn’t saving a local copy — don’t reload until your ${changes(pendingCount)} ${pendingCount === 1 ? "has" : "have"} been sent.`
        : "This browser isn’t saving a local copy, so a reload starts from the server."
      : "Some of the local copy couldn’t be kept.";

  return note === null || note === "" ? headline : `${headline} (${note})`;
}
