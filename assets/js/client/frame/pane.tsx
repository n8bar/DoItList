// The right-hand pane slot (m04.01 item 4.1).
//
// The frame owns the slot; routes fill it. It is empty in this arc — Arc 2's
// Details pane is its first tenant — and an empty slot renders NOTHING: no
// ghost gutter, no reserved column standing there looking broken. The column
// only joins the grid when there is something in it, and because the pane is a
// sibling of the main column (not a slice taken out of it) the main column's
// width does not change when a route fills it on a narrow screen.

import type { ReactNode } from "react";
import { createContext, useContext, useEffect } from "react";

export interface PaneControl {
  setPane(node: ReactNode | null): void;
}

const PaneContext = createContext<PaneControl | null>(null);

export function PaneProvider({ value, children }: { value: PaneControl; children: ReactNode }) {
  return <PaneContext.Provider value={value}>{children}</PaneContext.Provider>;
}

/**
 * Puts `node` in the frame's pane for as long as the calling screen is mounted,
 * and takes it away when the screen leaves. `null` means "no pane".
 */
export function usePane(node: ReactNode | null): void {
  const control = useContext(PaneContext);

  useEffect(() => {
    if (control === null) return;
    control.setPane(node);
    return () => control.setPane(null);
  }, [control, node]);
}
