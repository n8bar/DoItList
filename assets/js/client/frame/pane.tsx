// The right-hand pane slot (m04.01 item 4.1).
//
// The frame owns the slot; routes fill it with `<Pane>`. It is empty in this arc
// — Arc 2's Details pane is its first tenant — and an empty slot renders
// NOTHING: no ghost gutter, no reserved column standing there looking broken.
//
// The content is PORTALLED into the frame's `<aside>` rather than handed up as a
// React node. That is deliberate: an earlier version took the node as a prop and
// pushed it into frame state from an effect, which meant inline JSX (a new
// object every render) re-entered the effect, set state, re-rendered, and went
// round again. With a portal the frame only ever learns two things — that
// somebody is in the pane, and which element they are rendering into — so a
// tenant re-rendering its own content costs the frame nothing.

import type { ReactNode } from "react";
import { createContext, useContext, useEffect } from "react";
import { createPortal } from "react-dom";

export interface PaneControl {
  /** Claim the pane. Returns the release, which is safe to call twice. */
  acquire(): () => void;
  /** The mounted pane element, once the frame has it. */
  readonly host: HTMLElement | null;
}

const PaneContext = createContext<PaneControl | null>(null);

export function PaneProvider({ value, children }: { value: PaneControl; children: ReactNode }) {
  return <PaneContext.Provider value={value}>{children}</PaneContext.Provider>;
}

/**
 * Puts its children in the frame's pane for as long as it is mounted. Renders
 * nothing where it sits.
 */
export function Pane({ children }: { children: ReactNode }) {
  const control = useContext(PaneContext);

  useEffect(() => control?.acquire(), [control]);

  const host = control?.host ?? null;
  return host === null ? null : createPortal(children, host);
}
