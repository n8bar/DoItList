// The root error boundary (m04.01 item 2.3).
//
// React's render work is scheduled, not synchronous: a throw inside the tree
// lands long after `createRoot(...).render(...)` returned, and React responds
// by unmounting everything. Without this boundary the user is left staring at
// an empty `#app` — inert markup, which is exactly what the resilient-client
// spec forbids. The boundary hands the error to the startup guard, which paints
// the plain-DOM recovery screen.
import { Component, useEffect } from "react";
import type { ErrorInfo, ReactNode } from "react";

interface Props {
  children: ReactNode;
  onError: (error: unknown) => void;
}

export class RootBoundary extends Component<Props, { failed: boolean }> {
  override state = { failed: false };

  static getDerivedStateFromError() {
    return { failed: true };
  }

  override componentDidCatch(error: unknown, _info: ErrorInfo) {
    this.props.onError(error);
  }

  override render() {
    // Render nothing: the recovery screen is plain DOM written into #app by the
    // guard, because React is what just failed.
    return this.state.failed ? null : this.props.children;
  }
}

/**
 * Signals "the client painted" from inside the committed tree.
 *
 * An effect, not a render-time call: effects run only after React commits, so
 * a render that throws never reaches this and the document's watchdog stays
 * armed. Rendered last so the app's own effects run first.
 */
export function ReadyBeacon({ onReady }: { onReady: () => void }) {
  useEffect(() => {
    onReady();
  }, [onReady]);

  return null;
}
