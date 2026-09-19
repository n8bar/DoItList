// Offline, the last-known tree and every view action still work, a queueable
// write is acknowledged and kept, and a server-gated action fails in words
// (m04.03 5, item 6.6; UX_GUARDRAILS §6.5, §6.7, §6.8).
//
// The connection is driven to `offline` over the fake socket; the device's
// copy is installed into the sync session; then the pieces the screen wires
// are exercised with no server anywhere: collapse, selection, a toggle, undo.

import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { ApiClient, Result } from "../api/client.ts";
import { createConnection } from "../live/connection.ts";
import { RECONNECT_BUDGET } from "../live/connection_state.ts";
import { fakeTimers, fakeTransport } from "../live/fake_transport.ts";
import { createInitiativeSync } from "../live/refresh.ts";
import { createDomainStore } from "../state/domain.ts";
import { createUiStore, selectTask } from "../state/ui.ts";
import { NOT_AVAILABLE_OFFLINE, availableOffline, unavailableLabel } from "../tree/action_class.ts";
import { createAdapter, predictWrite } from "../tree/adapter.ts";
import { collapsedOf, createCollapseStore, setCollapsedIn } from "../tree/collapse_model.ts";
import { buildTree } from "../tree/gen.ts";
import type { TreeModel } from "../tree/model.ts";
import { fromSnapshot } from "../tree/model.ts";
import { OFFLINE_BANNER, degradedState, describeConnection, isOfflineState } from "./connection_model.ts";

const ID = 12;
// root 1 ─ 10 ─ 11
//        └ 20
const tree = () => buildTree([{ id: 10, children: [{ id: 11 }] }, { id: 20 }], { id: ID, seq: 4 });

const flush = async (): Promise<void> => {
  for (let i = 0; i < 8; i += 1) await new Promise((resolve) => setTimeout(resolve, 0));
};

describe("what still works offline (m04.03 6.6)", () => {
  it("the cached tree paints, view actions act at once, a write is acknowledged and kept, and undo answers in words", async () => {
    // --- no server anywhere ----------------------------------------------
    const reads: string[] = [];
    const posts: string[] = [];
    const api = {
      get: (path: string) => {
        reads.push(path);
        return Promise.resolve({ ok: false, error: { code: "network", status: 0, message: "Failed to fetch" } });
      },
      post: <T,>(_path: string, _body: unknown, headers?: Record<string, string>): Promise<Result<T>> => {
        posts.push(headers?.["idempotency-key"] ?? "");
        return Promise.resolve({ ok: false, error: { code: "network", status: 0, message: "Failed to fetch" } });
      },
    } as unknown as ApiClient;

    const socket = fakeTransport();
    const clock = fakeTimers();
    const domain = createDomainStore();
    const ui = createUiStore();
    const connection = createConnection({
      transport: socket.factory,
      onStatus: () => {},
      onDelta: (envelope) => sync.onDelta(envelope),
      onJoined: (id, seq) => sync.onJoined(id, seq),
      onAccessRevoked: (id) => sync.onAccessRevoked(id),
      timers: clock.timers,
      random: () => 0.5,
    });
    const sync = createInitiativeSync({
      api,
      domain,
      ui,
      onForbidden: () => {},
      timers: clock.timers,
      channel: {
        subscribe: (id) => connection.subscribeInitiative(id),
        unsubscribe: (id) => connection.unsubscribeInitiative(id),
      },
    });
    connection.connect();
    for (let i = 0; i <= RECONNECT_BUDGET; i += 1) socket.get().fail();
    assert.equal(connection.status(), "offline");

    // --- last-known content -----------------------------------------------
    const cached = fromSnapshot(tree());
    assert.equal(sync.installCached(cached), true);
    sync.watch(ID);
    const shown = () => domain.get().trees[ID] as TreeModel;
    assert.equal(shown().tasks[11]?.title, "Task 11", "the device's copy is on screen");
    assert.deepEqual(reads, [], "nothing was read to get here");

    let state = degradedState({ connection: connection.status(), pendingCount: 0, fatal: null });
    assert.equal(state, "offline-idle");
    assert.equal(isOfflineState(state), true);
    assert.equal(describeConnection(state).action, "retry", "the banner and the summary offer Try again");
    assert.match(OFFLINE_BANNER, /kept on this device/);

    // --- local view actions never wait (§6.5) ------------------------------
    const collapse = createCollapseStore();
    setCollapsedIn(collapse, 10, true);
    assert.equal(collapsedOf(collapse).get(10), true);
    setCollapsedIn(collapse, 10, false);
    assert.equal(collapsedOf(collapse).get(10), false);
    selectTask(ui, 11);
    assert.equal(ui.get().selectedTaskId, 11);
    connection.select(ID, 11);
    assert.deepEqual(reads, []);
    assert.deepEqual(posts, []);

    // --- a queueable write is acknowledged at once and kept (§6.7, §6.8) ----
    const unknown: string[] = [];
    const adapter = createAdapter({
      api,
      context: (id) => ({ model: domain.get().trees[id] as TreeModel }),
      sendContext: (id) => ({ model: sync.canonical(id) as TreeModel }),
      keyGen: () => "k1",
      onSubmit: ({ key, write }) =>
        sync.begin(ID, { key, predict: (base) => (write === null ? base : (predictWrite(write, { model: base }, -1) ?? base)), tempId: null }),
      onResult: () => assert.fail("offline, nothing is answered"),
      onUnknown: ({ key }) => unknown.push(key),
    });
    assert.equal(availableOffline("toggleComplete", true), true);
    void adapter.submit(ID, { kind: "toggleComplete", id: 11, done: true });
    assert.equal(shown().tasks[11]?.done, true, "acknowledged in the same step");
    await flush();
    assert.deepEqual(unknown, ["k1"], "parked, not failed");
    assert.deepEqual(posts, ["k1", "k1"], "one send and its one retry, then it waits");
    assert.equal(shown().tasks[11]?.done, true, "still shown as unsaved, never silently dropped");

    state = degradedState({ connection: connection.status(), pendingCount: 1, fatal: null });
    assert.equal(state, "offline-pending");
    assert.equal(describeConnection(state, 1).label, "Offline — 1 change waiting");

    // --- a server-gated action fails visibly, in place ----------------------
    assert.equal(availableOffline("undo", true), false);
    assert.equal(availableOffline("manageMembers", true), false);
    assert.equal(NOT_AVAILABLE_OFFLINE, "Not available offline");
    assert.equal(unavailableLabel("Undo"), "Undo — not available offline");

    // --- Try again is acknowledged at once ---------------------------------
    connection.retry();
    assert.equal(connection.status(), "connecting");
    assert.equal(socket.get().connects, 2);
  });
});
