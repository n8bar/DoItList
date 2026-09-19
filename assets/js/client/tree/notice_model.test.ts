import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { ApiError } from "../api/client.ts";
import { REJECTED_DEFAULT, historySentence, rejectionCode, rejectionDetail, rejectionSentence, warnRejection } from "./notice_model.ts";

const AGENT_PROSE = "Task 13495 was changed by someone else (expected_version 3, now 4). Re-read and retry.";

function refused(code: ApiError["code"], status = 422): ApiError {
  return { code, status, message: AGENT_PROSE };
}

/** A batch reply whose offending op carries `code`, under a generic top-level error. */
function batch(code: string, pointer?: string): ApiError {
  return {
    code: "unprocessable_entity",
    status: 422,
    message: "Operation at index 1 failed; the batch was rolled back.",
    payload: {
      error: { status: 422, code: "unprocessable_entity", message: "Operation at index 1 failed; the batch was rolled back." },
      results: [
        { index: 0, status: "not_applied" },
        { index: 1, status: "error", error: { code, message: AGENT_PROSE, ...(pointer === undefined ? {} : { pointer }) } },
      ],
    },
  };
}

describe("rejectionSentence (m04.02 item 7.14)", () => {
  it("maps each code to its sentence", () => {
    assert.equal(rejectionSentence(refused("conflict", 409)), "Someone changed this first.");
    assert.equal(rejectionSentence({ code: "duplicate" as ApiError["code"], status: 422, message: AGENT_PROSE }), "That change was already saved.");
    assert.equal(rejectionSentence(refused("forbidden", 403)), "You can't do that here.");
  });

  it("says the default for anything else", () => {
    for (const code of ["unprocessable_entity", "not_found", "network", "malformed", "unauthorized", "stale_session"] as const) {
      assert.equal(rejectionSentence(refused(code)), REJECTED_DEFAULT);
    }
    assert.equal(rejectionSentence({ code: "something_new" as ApiError["code"], status: 500, message: AGENT_PROSE }), REJECTED_DEFAULT);
  });

  it("reads the offending op's code under a batch's generic top-level error", () => {
    assert.equal(rejectionCode(batch("conflict")), "conflict");
    assert.equal(rejectionSentence(batch("conflict")), "Someone changed this first.");
    assert.equal(rejectionSentence(batch("forbidden")), "You can't do that here.");
    assert.equal(rejectionSentence(batch("unprocessable_entity", "title")), REJECTED_DEFAULT);
  });

  it("never leaks the API's message or its ids", () => {
    for (const error of [refused("conflict", 409), refused("forbidden", 403), refused("unprocessable_entity"), batch("conflict"), batch("not_found")]) {
      const sentence = rejectionSentence(error);
      assert.ok(!sentence.includes("13495"), sentence);
      assert.ok(!sentence.includes("expected_version"), sentence);
      assert.ok(!sentence.includes("index"), sentence);
      assert.notEqual(sentence, AGENT_PROSE);
    }
  });
});

describe("historySentence", () => {
  it("says nothing to undo or redo for the stack's own 422", () => {
    assert.equal(historySentence("undo", refused("unprocessable_entity")), "Nothing to undo.");
    assert.equal(historySentence("redo", refused("unprocessable_entity")), "Nothing to redo.");
  });

  it("uses the shared sentences for other codes", () => {
    assert.equal(historySentence("undo", refused("forbidden", 403)), "You can't do that here.");
    assert.equal(historySentence("redo", refused("conflict", 409)), "Someone changed this first.");
    assert.equal(historySentence("undo", refused("network", 0)), REJECTED_DEFAULT);
  });
});

describe("warnRejection", () => {
  it("hands the API's words to the log, with the op's index and pointer", () => {
    const lines: unknown[][] = [];
    warnRejection("the pane delete", batch("conflict", "expected_version"), (...args) => lines.push(args));
    assert.equal(lines.length, 1);
    assert.equal(lines[0]?.[0], "the pane delete: the API refused the change");
    assert.deepEqual(lines[0]?.[1], { code: "conflict", status: 422, message: AGENT_PROSE, index: 1, pointer: "expected_version" });
  });

  it("logs the top-level words when no op is named", () => {
    assert.deepEqual(rejectionDetail(refused("forbidden", 403)), { code: "forbidden", status: 403, message: AGENT_PROSE });
  });
});
