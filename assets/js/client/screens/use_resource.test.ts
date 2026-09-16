import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { ApiError, Result } from "../api/client.ts";
import { readUsable } from "./use_resource.ts";

const ok = <T,>(data: T): Result<T> => ({ ok: true, data });

const bad = (message: string): Result<never> => ({
  ok: false,
  error: { code: "not_found", status: 404, message } satisfies ApiError,
});

/** Hands back the queued answers in order, and records how often it was asked. */
function reader(answers: Result<string>[]) {
  let calls = 0;
  return {
    calls: () => calls,
    read: () => {
      calls += 1;
      return Promise.resolve(answers[calls - 1] ?? bad("ran out"));
    },
  };
}

describe("a read the screen cannot adopt (item 1.6.2)", () => {
  it("reads once more when the first answer is refused", async () => {
    const source = reader([ok("broken"), ok("good")]);
    const adopted: string[] = [];

    const attempt = await readUsable({
      read: source.read,
      adopt: (data: string) => {
        if (data === "broken") throw new Error("not a tree");
        adopted.push(data);
      },
    });

    assert.deepEqual(attempt, { outcome: "ready" });
    assert.equal(source.calls(), 2);
    assert.deepEqual(adopted, ["good"]);
  });

  it("gives up after the second refusal, carrying the reason", async () => {
    const source = reader([ok("broken"), ok("broken")]);

    const attempt = await readUsable({
      read: source.read,
      adopt: () => {
        throw new Error("not a tree");
      },
    });

    assert.equal(attempt.outcome, "unusable");
    assert.equal(source.calls(), 2, "it read exactly twice");
    assert.equal(
      attempt.outcome === "unusable" && (attempt.error as Error).message,
      "not a tree",
    );
  });

  it("does not re-read a request that simply failed", async () => {
    const source = reader([bad("gone")]);

    const attempt = await readUsable({ read: source.read, adopt: () => {} });

    assert.equal(attempt.outcome, "failed");
    assert.equal(source.calls(), 1);
  });

  it("adopts nothing once nobody is waiting any more", async () => {
    const source = reader([ok("good")]);
    let adopted = 0;

    const attempt = await readUsable({
      read: source.read,
      adopt: () => {
        adopted += 1;
      },
      alive: () => false,
    });

    assert.deepEqual(attempt, { outcome: "abandoned" });
    assert.equal(adopted, 0);
  });
});
