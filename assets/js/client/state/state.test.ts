import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { createStore } from "./store.ts";
import { createDomainStore, initialDomainState, initiativeTree, putInitiativeTree } from "./domain.ts";
import { createRecoveryStore, initialRecoveryState, setConnectionStatus } from "./recovery.ts";
import { createPreferencesStore, initialPreferencesState, setThemePreference } from "./preferences.ts";
import { createUiStore, initialUiState, rememberPlace, setRoute } from "./ui.ts";
import { createStores } from "./stores.ts";
import type { InitiativeTree } from "../api/types.ts";

const tree = (id: number, name: string): InitiativeTree => ({
  id,
  name,
  subtitle: null,
  role: "owner",
  progress: 0,
  progress_calc: "leaf_average",
  unit_count: 0,
  index_style: "numerical",
  root_task_id: id * 10,
  version: 1,
  tasks: [],
});

describe("createStore", () => {
  it("returns the initial value until something sets it", () => {
    const store = createStore({ n: 1 });
    assert.deepEqual(store.get(), { n: 1 });
  });

  it("notifies subscribers on a change", () => {
    const store = createStore(0);
    let calls = 0;
    store.subscribe(() => {
      calls += 1;
    });
    store.set(1);
    store.set((n) => n + 1);
    assert.equal(store.get(), 2);
    assert.equal(calls, 2);
  });

  it("does not notify when the value is unchanged", () => {
    const value = { n: 1 };
    const store = createStore(value);
    let calls = 0;
    store.subscribe(() => {
      calls += 1;
    });
    store.set(value);
    store.set(() => value);
    assert.equal(calls, 0);
  });

  it("lets a listener unsubscribe without disturbing the others", () => {
    const store = createStore(0);
    const seen: string[] = [];
    const off = store.subscribe(() => {
      seen.push("a");
      off();
    });
    store.subscribe(() => seen.push("b"));
    store.set(1);
    store.set(2);
    assert.deepEqual(seen, ["a", "b", "b"]);
  });
});

describe("store separation (item 3.1)", () => {
  // The rule, enforced rather than remembered: domain state never holds UI
  // fields and vice versa. A field that appears in two stores is two sources of
  // truth with two different lifetimes.
  const shapes = {
    domain: initialDomainState,
    recovery: initialRecoveryState,
    preferences: initialPreferencesState,
    ui: initialUiState,
  } as const;

  it("gives each store a non-empty shape", () => {
    for (const [name, shape] of Object.entries(shapes)) {
      assert.ok(Object.keys(shape).length > 0, `${name} has no fields`);
    }
  });

  it("keeps the four state shapes disjoint", () => {
    const names = Object.keys(shapes) as (keyof typeof shapes)[];
    for (const a of names) {
      for (const b of names) {
        if (a >= b) continue;
        const shared = Object.keys(shapes[a]).filter((key) =>
          Object.prototype.hasOwnProperty.call(shapes[b], key),
        );
        assert.deepEqual(shared, [], `${a} and ${b} both declare ${shared.join(", ")}`);
      }
    }
  });

  it("keeps the stores independent: writing one does not notify another", () => {
    const stores = createStores();
    const woken: string[] = [];
    stores.domain.subscribe(() => woken.push("domain"));
    stores.recovery.subscribe(() => woken.push("recovery"));
    stores.preferences.subscribe(() => woken.push("preferences"));
    stores.ui.subscribe(() => woken.push("ui"));

    setRoute(stores.ui, { kind: "account" });
    assert.deepEqual(woken, ["ui"]);

    setConnectionStatus(stores.recovery, "offline");
    assert.deepEqual(woken, ["ui", "recovery"]);

    setThemePreference(stores.preferences, "dark");
    assert.deepEqual(woken, ["ui", "recovery", "preferences"]);

    putInitiativeTree(stores.domain, tree(1, "Q3"));
    assert.deepEqual(woken, ["ui", "recovery", "preferences", "domain"]);
  });
});

describe("domain store", () => {
  it("files trees by id without disturbing the others", () => {
    const store = createDomainStore();
    putInitiativeTree(store, tree(1, "Q3"));
    putInitiativeTree(store, tree(2, "Q4"));
    assert.equal(initiativeTree(store.get(), 1)?.name, "Q3");
    assert.equal(initiativeTree(store.get(), 2)?.name, "Q4");
  });

  it("reports an unread tree as undefined rather than a blank one", () => {
    assert.equal(initiativeTree(createDomainStore().get(), 7), undefined);
  });
});

describe("recovery store", () => {
  it("starts connecting with nothing queued", () => {
    const store = createRecoveryStore();
    assert.equal(store.get().connection, "connecting");
    assert.deepEqual(store.get().pendingWrites, []);
    assert.equal(store.get().snapshotVersion, null);
  });

  it("ignores a status write that changes nothing", () => {
    const store = createRecoveryStore({ connection: "live" });
    let calls = 0;
    store.subscribe(() => {
      calls += 1;
    });
    setConnectionStatus(store, "live");
    assert.equal(calls, 0);
  });
});

describe("preferences store", () => {
  it("defaults theme to system", () => {
    assert.equal(createPreferencesStore().get().theme, "system");
  });

  it("sets the theme preference", () => {
    const store = createPreferencesStore();
    setThemePreference(store, "dark");
    assert.equal(store.get().theme, "dark");
  });
});

describe("ui store", () => {
  it("remembers a place per history entry", () => {
    const store = createUiStore();
    rememberPlace(store, "k1", { scrollTop: 120, focusElementId: "task-3" });
    rememberPlace(store, "k2", { scrollTop: 0, focusElementId: null });
    assert.deepEqual(store.get().navigationMemory, [
      { key: "k1", scrollTop: 120, focusElementId: "task-3" },
      { key: "k2", scrollTop: 0, focusElementId: null },
    ]);
  });

  it("starts on the Initiatives route with nothing selected", () => {
    const store = createUiStore();
    assert.deepEqual(store.get().route, { kind: "initiatives" });
    assert.equal(store.get().selectedTaskId, null);
  });
});
