import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { createStore, derive } from "./store.ts";
import {
  createDomainStore,
  forgetInitiative,
  initialDomainState,
  members as loadedMembers,
  putMembers,
  putTree,
  tree as loadedTree,
} from "./domain.ts";
import {
  createRecoveryStore,
  initialRecoveryState,
  pendingWriteFrom,
  waitingCount,
  setConnectionStatus,
  setPendingWrites,
  setSnapshotMeta,
  setStorageHealth,
} from "./recovery.ts";
import { createPreferencesStore, initialPreferencesState, setThemePreference } from "./preferences.ts";
import { createUiStore, initialUiState, rememberPlace, setRoute } from "./ui.ts";
import { createStores } from "./stores.ts";
import { fromSnapshot } from "../tree/model.ts";

const tree = (id: number, name: string) =>
  fromSnapshot({
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
    seq: 1,
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

    putTree(stores.domain, tree(1, "Q3"));
    assert.deepEqual(woken, ["ui", "recovery", "preferences", "domain"]);
  });
});

describe("domain store", () => {
  it("files trees by id without disturbing the others", () => {
    const store = createDomainStore();
    putTree(store, tree(1, "Q3"));
    putTree(store, tree(2, "Q4"));
    assert.equal(loadedTree(store.get(), 1)?.header.name, "Q3");
    assert.equal(loadedTree(store.get(), 2)?.header.name, "Q4");
  });

  it("reports an unread tree as undefined rather than a blank one", () => {
    assert.equal(loadedTree(createDomainStore().get(), 7), undefined);
  });

  it("files members per Initiative, and reads an unread list as empty", () => {
    const store = createDomainStore();
    assert.deepEqual(loadedMembers(store.get(), 1), []);

    putMembers(store, 1, [{ user_id: 5, role: "owner", name: "Ada L", username: "ada" }]);
    putMembers(store, 2, [{ user_id: 6, role: "viewer", name: null, username: "bo" }]);

    assert.deepEqual(
      loadedMembers(store.get(), 1).map((m) => m.username),
      ["ada"],
    );
    assert.deepEqual(
      loadedMembers(store.get(), 2).map((m) => m.username),
      ["bo"],
    );
  });

  it("drops an Initiative's members with its tree when access goes away", () => {
    const store = createDomainStore();
    putTree(store, tree(1, "Q3"));
    putMembers(store, 1, [{ user_id: 5, role: "owner", name: "Ada L", username: "ada" }]);

    forgetInitiative(store, 1);

    assert.equal(loadedTree(store.get(), 1), undefined);
    assert.deepEqual(loadedMembers(store.get(), 1), []);
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

  it("starts with the local store still opening and nothing to say about it", () => {
    const store = createRecoveryStore();
    assert.equal(store.get().storage, "opening");
    assert.equal(store.get().storageNote, null);
  });

  it("records the local store's health and why (items 3.5–3.6)", () => {
    const store = createRecoveryStore();
    setStorageHealth(store, "unavailable", "private mode");
    assert.equal(store.get().storage, "unavailable");
    assert.equal(store.get().storageNote, "private mode");
  });

  it("ignores a storage write that changes nothing", () => {
    const store = createRecoveryStore({ storage: "ready" });
    let calls = 0;
    store.subscribe(() => {
      calls += 1;
    });
    setStorageHealth(store, "ready");
    assert.equal(calls, 0);
  });

  it("records the newest snapshot, and that there is none", () => {
    const store = createRecoveryStore();
    setSnapshotMeta(store, { initiativeId: 12, version: 7, seq: 40, savedAt: 900 });
    assert.equal(store.get().snapshotInitiativeId, 12);
    assert.equal(store.get().snapshotVersion, 7);
    assert.equal(store.get().snapshotSeq, 40);
    assert.equal(store.get().snapshotAt, 900);

    setSnapshotMeta(store, null);
    assert.equal(store.get().snapshotInitiativeId, null);
    assert.equal(store.get().snapshotVersion, null);
    assert.equal(store.get().snapshotSeq, null);
    assert.equal(store.get().snapshotAt, null);
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

describe("writes this device has not sent yet", () => {
  it("reads a queued op off the device as a pending write", () => {
    const write = pendingWriteFrom({
      key: "op-7",
      initiativeId: 3,
      createdAt: 1_700_000_000_000,
      payload: { op: "update_task" },
    });

    assert.equal(write.id, "op-7");
    assert.equal(write.initiativeId, 3);
    assert.equal(write.queuedAt, 1_700_000_000_000);
    assert.deepEqual(write.operation, { op: "update_task" });
    assert.equal(write.status, "queued");
  });

  it("carries where each stands, and counts only the ones still waiting on the server (m04.03 4.6.2)", () => {
    const at = (status: string) => pendingWriteFrom({ key: status, initiativeId: 1, createdAt: 1, payload: { status } });
    assert.equal(at("sent").status, "sent");
    assert.equal(at("rejected").status, "rejected");
    assert.equal(waitingCount([at("queued"), at("sent"), at("rejected")]), 2);
  });

  it("puts them in the store, so the count the user is shown is the real one", () => {
    const store = createRecoveryStore();

    setPendingWrites(store, [
      pendingWriteFrom({ key: "a", initiativeId: 1, createdAt: 1, payload: null }),
    ]);

    assert.equal(store.get().pendingWrites.length, 1);
  });

  it("does not churn the state when there is nothing queued and nothing was", () => {
    const store = createRecoveryStore();
    const before = store.get();

    setPendingWrites(store, []);

    assert.equal(store.get(), before);
  });
});

describe("derive (item 7.18)", () => {
  it("hands back the same value until the source changes, and forwards subscriptions", () => {
    const source = createStore({ n: 1, other: "a" });
    let computed = 0;
    const view = derive(source, (state) => {
      computed += 1;
      return { doubled: state.n * 2 };
    });
    const first = view.get();
    assert.deepEqual(first, { doubled: 2 });
    assert.equal(view.get(), first);
    assert.equal(computed, 1);

    let notified = 0;
    view.subscribe(() => (notified += 1));
    source.set({ n: 2, other: "a" });
    assert.equal(notified, 1);
    assert.deepEqual(view.get(), { doubled: 4 });
    assert.equal(computed, 2);
  });
});
