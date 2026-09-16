import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { createNetworkSignal } from "./network.ts";

function fakeTarget() {
  const listeners = new Map<string, Set<() => void>>();
  return {
    target: {
      addEventListener(type: string, listener: () => void) {
        const set = listeners.get(type) ?? new Set();
        set.add(listener);
        listeners.set(type, set);
      },
      removeEventListener(type: string, listener: () => void) {
        listeners.get(type)?.delete(listener);
      },
    },
    fire: (type: string) => {
      for (const listener of [...(listeners.get(type) ?? [])]) listener();
    },
    count: () => [...listeners.values()].reduce((total, set) => total + set.size, 0),
  };
}

describe("the browser's network signal", () => {
  it("reports both directions", () => {
    const seen: boolean[] = [];
    const t = fakeTarget();

    createNetworkSignal(t.target, () => true).subscribe((online) => seen.push(online));
    t.fire("offline");
    t.fire("online");

    assert.deepEqual(seen, [false, true]);
  });

  it("passes on what the browser currently says", () => {
    let online = false;
    const t = fakeTarget();

    assert.equal(createNetworkSignal(t.target, () => online).online(), false);
    online = true;
    assert.equal(createNetworkSignal(t.target, () => online).online(), true);
  });

  it("lets go of the window when it is unsubscribed", () => {
    const t = fakeTarget();
    const stop = createNetworkSignal(t.target, () => true).subscribe(() => {});

    assert.equal(t.count(), 2);
    stop();
    assert.equal(t.count(), 0);
  });
});
