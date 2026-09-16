import { deepStrictEqual, notStrictEqual } from "node:assert/strict";
import { describe, it } from "node:test";

import { markAllReadOperation, markAllReadRequest } from "./notification_ops.js";

describe("the mark-all-read operation (item 4.6.3)", () => {
  it("speaks the engine's envelope: op, type, data", () => {
    // Pinned literally, because the engine reads `op`/`type`/`data` and answers
    // anything else with 422. `test/doit_web/client/notification_ops_test.exs`
    // pins the same bytes against the real endpoint.
    deepStrictEqual(markAllReadOperation(), {
      op: "update",
      type: "notification",
      data: { all: true },
    });
  });

  it("is a whole request body, ready to post", () => {
    deepStrictEqual(markAllReadRequest(), {
      operations: [{ op: "update", type: "notification", data: { all: true } }],
    });
  });

  it("hands out a fresh object, so one caller cannot poison the next", () => {
    const first = markAllReadRequest();
    const second = markAllReadRequest();
    notStrictEqual(first, second);
    notStrictEqual(first.operations[0], second.operations[0]);
  });
});
