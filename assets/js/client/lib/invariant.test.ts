import { strict as assert } from "node:assert";
import { test } from "node:test";

import { invariant, InvariantError } from "./invariant.ts";

test("invariant passes a truthy condition through", () => {
  assert.doesNotThrow(() => invariant(1, "never"));
});

test("invariant throws an InvariantError carrying the message", () => {
  assert.throws(() => invariant(false, "boom"), (error: unknown) => {
    assert.ok(error instanceof InvariantError);
    assert.equal(error.message, "boom");
    return true;
  });
});
