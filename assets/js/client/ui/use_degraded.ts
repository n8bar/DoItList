// The degraded state, as a hook (m04.03 5.1.2).
//
// One derivation (`degradedState`) read off the recovery store, so the summary,
// the offline banner and every control that greys itself out offline are all
// answering the same question from the same numbers. A control that needs
// only "are we offline?" asks `useOffline`, which re-renders it only when that
// yes/no flips — not on every pending-count change.

import { useServices } from "../services.tsx";
import type { RecoveryState } from "../state/recovery.ts";
import { waitingCount } from "../state/recovery.ts";
import { useStoreValue } from "../state/use_store.ts";
import type { DegradedState } from "./connection_model.ts";
import { degradedState, isOfflineState } from "./connection_model.ts";

const selectDegraded = (state: RecoveryState): DegradedState =>
  degradedState({
    connection: state.connection,
    pendingCount: waitingCount(state.pendingWrites),
    fatal: state.fatalError,
  });

export function useDegradedState(): DegradedState {
  const { stores } = useServices();
  return useStoreValue(stores.recovery, selectDegraded);
}

const selectOffline = (state: RecoveryState): boolean => isOfflineState(selectDegraded(state));

/** True while the client has stopped trying on its own (either offline state). */
export function useOffline(): boolean {
  const { stores } = useServices();
  return useStoreValue(stores.recovery, selectOffline);
}
