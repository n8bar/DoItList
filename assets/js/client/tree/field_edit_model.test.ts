import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  actorName,
  blur,
  cancel,
  cancelable,
  dirty,
  focus,
  idle,
  incomingNotice,
  input,
  remote,
  shownValue,
} from "./field_edit_model.ts";
import type { FieldEdit } from "./field_edit_model.ts";

const focused: FieldEdit = focus(idle, "Ship it");

describe("a focused, untouched field (4.2.1)", () => {
  it("focus takes the record's value as baseline and draft", () => {
    assert.deepEqual(focused, { baseline: "Ship it", draft: "Ship it", incoming: null });
    assert.equal(dirty(focused), false);
    assert.equal(cancelable(focused), false);
  });

  it("a remote write moves the value and the baseline in place, with nothing to say", () => {
    const next = remote(focused, "Ship it today", "Ann");
    assert.deepEqual(next, { baseline: "Ship it today", draft: "Ship it today", incoming: null });
    assert.equal(dirty(next), false);
    assert.equal(shownValue(next, "stale record"), "Ship it today");
  });

  it("a remote write to a field that is not focused only moves the baseline", () => {
    assert.deepEqual(remote(idle, "Elsewhere", "Ann"), { baseline: "Elsewhere", draft: null, incoming: null });
  });

  it("a remote write equal to the baseline changes nothing", () => {
    assert.equal(remote(focused, "Ship it", "Ann"), focused);
  });

  it("focus keeps a draft already held (a refused edit comes back as one)", () => {
    const refused: FieldEdit = { baseline: "", draft: "Ship it!!", incoming: null };
    assert.deepEqual(focus(refused, "Ship it"), { baseline: "Ship it", draft: "Ship it!!", incoming: null });
  });
});

describe("a dirty field (4.2.2)", () => {
  const typed = input(focused, "Ship it now");

  it("typing makes it dirty and shows the draft", () => {
    assert.equal(dirty(typed), true);
    assert.equal(shownValue(typed, "Ship it"), "Ship it now");
    assert.equal(input(typed, "Ship it now"), typed, "same text, same state");
  });

  it("a remote write keeps the draft exactly and parks the incoming value", () => {
    const next = remote(typed, "Ship it today", "Ann");
    assert.deepEqual(next, {
      baseline: "Ship it",
      draft: "Ship it now",
      incoming: { value: "Ship it today", by: "Ann" },
    });
    assert.equal(cancelable(next), true);
    assert.equal(
      incomingNotice(next.incoming as NonNullable<FieldEdit["incoming"]>),
      'Ann changed this to "Ship it today" while you were editing. Saving will overwrite it.',
    );
  });

  it("a second remote write replaces the first in the notice", () => {
    const first = remote(typed, "Ship it today", "Ann");
    const second = remote(first, "Ship it tomorrow", "Bob");
    assert.deepEqual(second.incoming, { value: "Ship it tomorrow", by: "Bob" });
    assert.equal(second.draft, "Ship it now");
  });

  it("a remote write equal to the draft clears the incoming: nothing to warn about", () => {
    const waiting = remote(typed, "Ship it today", "Ann");
    const agreed = remote(waiting, "Ship it now", "Bob");
    assert.deepEqual(agreed, { baseline: "Ship it now", draft: "Ship it now", incoming: null });
    assert.equal(dirty(agreed), false);
  });

  it("a remote write back to the baseline clears the incoming", () => {
    const waiting = remote(typed, "Ship it today", "Ann");
    const back = remote(waiting, "Ship it", "Ann");
    assert.deepEqual(back, { baseline: "Ship it", draft: "Ship it now", incoming: null });
  });

  it("typing keeps the incoming waiting, unless the user types that very value", () => {
    const waiting = remote(typed, "Ship it today", "Ann");
    const more = input(waiting, "Ship it now!");
    assert.deepEqual(more.incoming, { value: "Ship it today", by: "Ann" });
    assert.deepEqual(input(waiting, "Ship it today"), {
      baseline: "Ship it today",
      draft: "Ship it today",
      incoming: null,
    });
  });

  it("blur clears everything: the caller saved the draft, the field shows the record", () => {
    const waiting = remote(typed, "Ship it today", "Ann");
    assert.deepEqual(blur(waiting), idle);
    assert.equal(shownValue(blur(waiting), "Ship it now"), "Ship it now");
  });
});

describe("Cancel (4.3)", () => {
  it("adopts the waiting value as value and baseline and clears the notice", () => {
    const waiting = remote(input(focused, "Ship it now"), "Ship it today", "Ann");
    const next = cancel(waiting);
    assert.deepEqual(next, { baseline: "Ship it today", draft: "Ship it today", incoming: null });
    assert.equal(dirty(next), false);
    assert.equal(cancelable(next), false);
  });

  it("does nothing when nothing is waiting", () => {
    const typed = input(focused, "Ship it now");
    assert.equal(cancel(typed), typed);
    assert.equal(cancel(focused), focused);
  });
});

describe("who to name", () => {
  it("the actor's name, their username when the name is blank, or Someone", () => {
    assert.equal(actorName({ name: "Ann Lee", username: "ann" }), "Ann Lee");
    assert.equal(actorName({ name: "", username: "ann" }), "ann");
    assert.equal(actorName(null), "Someone");
  });
});
