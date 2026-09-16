import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  MAX_NOTICES,
  addNotice,
  autoDismissMs,
  noticeRole,
  removeNotice,
} from "./notices.ts";
import { createUiStore, dismissNotice, pushNotice } from "./ui.ts";

describe("the notice list (item 4.3)", () => {
  it("adds newest first, so the newest is the one nearest the user", () => {
    const one = addNotice([], { id: "a", kind: "info", title: null, message: "first" });
    const two = addNotice(one, { id: "b", kind: "info", title: null, message: "second" });

    assert.deepEqual(
      two.map((notice) => notice.id),
      ["b", "a"],
    );
  });

  it("does not stack the same message twice", () => {
    const one = addNotice([], { id: "a", kind: "error", title: null, message: "Couldn’t save." });
    const again = addNotice(one, {
      id: "b",
      kind: "error",
      title: null,
      message: "Couldn’t save.",
    });

    assert.equal(again, one, "a repeat of a showing notice is not a second notice");
  });

  it("keeps a repeat of a DIFFERENT kind — the severity changed", () => {
    const one = addNotice([], { id: "a", kind: "info", title: null, message: "Saved." });
    const again = addNotice(one, { id: "b", kind: "error", title: null, message: "Saved." });

    assert.equal(again.length, 2);
  });

  it("caps the stack, dropping the oldest", () => {
    let list = addNotice([], { id: "0", kind: "info", title: null, message: "m0" });
    for (let n = 1; n <= MAX_NOTICES; n += 1) {
      list = addNotice(list, { id: `${n}`, kind: "info", title: null, message: `m${n}` });
    }

    assert.equal(list.length, MAX_NOTICES);
    assert.equal(
      list.some((notice) => notice.id === "0"),
      false,
      "the oldest notice made way",
    );
  });

  it("removes by id, and leaves the list alone when the id is gone", () => {
    const list = addNotice([], { id: "a", kind: "info", title: null, message: "m" });

    assert.deepEqual(removeNotice(list, "a"), []);
    assert.equal(removeNotice(list, "nope"), list);
  });

  it("speaks errors, states everything else (guardrails §2.3, §4.1)", () => {
    assert.equal(noticeRole("error"), "alert");
    assert.equal(noticeRole("info"), "status");
    assert.equal(noticeRole("success"), "status");
  });

  it("auto-dismisses success only — an error waits for the user", () => {
    assert.ok((autoDismissMs("success") ?? 0) > 0);
    assert.equal(autoDismissMs("info"), null);
    assert.equal(autoDismissMs("error"), null);
  });
});

describe("the notices slice of the ui store", () => {
  it("pushes, hands back the id, and dismisses by it", () => {
    const store = createUiStore();

    const id = pushNotice(store, { kind: "success", message: "Saved." });
    assert.equal(store.get().notices.length, 1);
    assert.equal(store.get().notices[0]?.message, "Saved.");
    assert.equal(store.get().notices[0]?.kind, "success");

    dismissNotice(store, id);
    assert.deepEqual(store.get().notices, []);
  });

  it("gives every notice its own id", () => {
    const store = createUiStore();
    const first = pushNotice(store, { kind: "info", message: "one" });
    const second = pushNotice(store, { kind: "info", message: "two" });

    assert.notEqual(first, second);
  });

  it("returns the showing notice's id when the message repeats", () => {
    const store = createUiStore();
    const first = pushNotice(store, { kind: "error", message: "Couldn’t reach the server." });
    const second = pushNotice(store, { kind: "error", message: "Couldn’t reach the server." });

    assert.equal(second, first);
    assert.equal(store.get().notices.length, 1);
  });

  it("does not wake subscribers when nothing changed", () => {
    const store = createUiStore();
    let woken = 0;
    store.subscribe(() => {
      woken += 1;
    });

    pushNotice(store, { kind: "info", message: "one" });
    dismissNotice(store, "not-a-notice");
    assert.equal(woken, 1);
  });
});
