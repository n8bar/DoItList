// The things every screen needs, in one place (m04.01 worklist 3).
//
// The API client, the four stores and the live connection are created once at
// boot and handed down by context. None of them is React state, so none of them
// is rebuilt by a route change — that is the whole point of the seam
// (guardrail §7.4).

import type { ReactNode } from "react";
import { createContext, useContext } from "react";

import type { ApiClient, ApiError } from "./api/client.ts";
import type { Connection } from "./live/connection.ts";
import type { InitiativeSync } from "./live/refresh.ts";
import type { Stores } from "./state/stores.ts";
import type { ClientCache } from "./storage/client_cache.ts";

export interface Services {
  readonly api: ApiClient;
  readonly stores: Stores;
  readonly connection: Connection;
  /** What the live channel makes the client re-read, and the index's background revalidation. */
  readonly sync: InitiativeSync;
  /** This account's local recovery cache. Never throws at a screen. */
  readonly cache: ClientCache;
  /**
   * Hands a failure to the app shell. Returns `true` when the shell took it
   * over (the session ended, or access was refused) and the screen should stop
   * rendering its own error; `false` when the screen owns the failure and
   * should show it in place with a way to retry.
   */
  escalate(error: ApiError): boolean;
}

const ServicesContext = createContext<Services | null>(null);

export function ServicesProvider({ value, children }: { value: Services; children: ReactNode }) {
  return <ServicesContext.Provider value={value}>{children}</ServicesContext.Provider>;
}

export function useServices(): Services {
  const value = useContext(ServicesContext);
  if (value === null) throw new Error("useServices was called outside a <ServicesProvider>.");
  return value;
}
