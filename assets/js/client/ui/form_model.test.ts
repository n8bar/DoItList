import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { SAVING_LABEL, describedBy, fieldErrorsFrom, fieldIds } from "./form_model.ts";

describe("field wiring (guardrails §2.2, §4.1)", () => {
  it("derives the ids a field needs from the form and the field name", () => {
    const ids = fieldIds("task-form", "title");

    assert.equal(ids.inputId, "task-form-title");
    assert.equal(ids.descriptionId, "task-form-title-description");
    assert.equal(ids.errorId, "task-form-title-error");
  });

  it("points the input at whichever of its two helpers exist", () => {
    const ids = fieldIds("task-form", "title");

    assert.equal(describedBy(ids, { description: false, error: false }), undefined);
    assert.equal(describedBy(ids, { description: true, error: false }), ids.descriptionId);
    assert.equal(describedBy(ids, { description: false, error: true }), ids.errorId);
    assert.equal(
      describedBy(ids, { description: true, error: true }),
      `${ids.descriptionId} ${ids.errorId}`,
      "the error is read last, so it is the last thing heard",
    );
  });

  it("names the in-flight submit state", () => {
    assert.ok(SAVING_LABEL.length > 0);
  });
});

describe("turning the server's per-op errors into field errors (item 4.2)", () => {
  const rejected = {
    error: {
      status: 422,
      code: "unprocessable_entity",
      message: "Operation at index 1 failed; the batch was rolled back.",
    },
    results: [
      { index: 0, lid: "t1", status: "not_applied" },
      {
        index: 1,
        status: "error",
        error: { code: "unprocessable_entity", message: "title can't be blank", pointer: "title" },
      },
    ],
  };

  it("files a per-op error under the field it points at", () => {
    assert.deepEqual(fieldErrorsFrom(rejected), { title: "title can't be blank" });
  });

  it("keeps the FIRST error for a field — the batch stopped there", () => {
    const twice = {
      results: [
        { index: 0, status: "error", error: { message: "first", pointer: "title" } },
        { index: 1, status: "error", error: { message: "second", pointer: "title" } },
      ],
    };

    assert.deepEqual(fieldErrorsFrom(twice), { title: "first" });
  });

  it("reads a pointer on a single-error response too", () => {
    assert.deepEqual(
      fieldErrorsFrom({ error: { code: "unprocessable_entity", message: "is taken", pointer: "name" } }),
      { name: "is taken" },
    );
  });

  it("files nothing when the failure names no field", () => {
    assert.deepEqual(fieldErrorsFrom({ error: { code: "forbidden", message: "nope" } }), {});
    assert.deepEqual(fieldErrorsFrom(null), {});
    assert.deepEqual(fieldErrorsFrom("not json"), {});
    assert.deepEqual(fieldErrorsFrom({ results: [{ index: 0, status: "ok" }] }), {});
  });

  it("ignores a pointer that is not a usable field name", () => {
    assert.deepEqual(fieldErrorsFrom({ error: { message: "m", pointer: "" } }), {});
    assert.deepEqual(fieldErrorsFrom({ error: { message: "m", pointer: 7 } }), {});
    assert.deepEqual(fieldErrorsFrom({ error: { pointer: "title" } }), {});
  });
});
