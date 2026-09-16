// The client's four stores, created together (m04.01 item 3.1).
//
// One bundle, four separate values — the client never has "a state object".
// A screen that needs the loaded tree subscribes to `domain` and is not woken
// by a scroll; the connection banner subscribes to `recovery` and is not woken
// by a selection.

import type { DomainState, DomainStore } from "./domain.ts";
import { createDomainStore } from "./domain.ts";
import type { PreferencesState, PreferencesStore } from "./preferences.ts";
import { createPreferencesStore } from "./preferences.ts";
import type { RecoveryState, RecoveryStore } from "./recovery.ts";
import { createRecoveryStore } from "./recovery.ts";
import type { UiState, UiStore } from "./ui.ts";
import { createUiStore } from "./ui.ts";

export interface Stores {
  readonly domain: DomainStore;
  readonly recovery: RecoveryStore;
  readonly preferences: PreferencesStore;
  readonly ui: UiStore;
}

export interface StoreSeeds {
  domain?: Partial<DomainState>;
  recovery?: Partial<RecoveryState>;
  preferences?: Partial<PreferencesState>;
  ui?: Partial<UiState>;
}

export function createStores(seeds: StoreSeeds = {}): Stores {
  return {
    domain: createDomainStore(seeds.domain ?? {}),
    recovery: createRecoveryStore(seeds.recovery ?? {}),
    preferences: createPreferencesStore(seeds.preferences ?? {}),
    ui: createUiStore(seeds.ui ?? {}),
  };
}
