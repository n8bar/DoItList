import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { HistoryResult, TaskResult } from "./delta.ts";
import {
  applyDelta,
  deltaFromHistoryResult,
  deltaFromOpResult,
  deltaFromSnapshot,
} from "./delta.ts";
import { buildTree } from "./gen.ts";
import { fromSnapshot } from "./model.ts";
import { InvalidTreeError, validateModel } from "./validate.ts";

const base = () =>
  fromSnapshot(
    buildTree([
      { id: 10, title: "Cabinets", children: [{ id: 11, title: "Doors" }, { id: 12 }] },
      { id: 20 },
    ]),
  );

const result = (over: Partial<TaskResult> = {}): TaskResult => ({
  id: 11,
  type: "task",
  title: "Doors",
  parent_id: 10,
  status: "open",
  done: false,
  progress: 0,
  manual_progress: 0,
  priority: "normal",
  assignee_id: null,
  version: 4,
  ...over,
});

const ok = (model: ReturnType<typeof base>) => {
  const verdict = validateModel(model);
  assert.equal(verdict.ok, true, verdict.ok ? "" : verdict.reason);
  return model;
};

describe("deltaFromOpResult", () => {
  it("carries the fields the op result has and no others", () => {
    const delta = deltaFromOpResult(result({ title: "Handles", version: 9 }));
    assert.deepEqual(delta.removed, []);
    assert.deepEqual(Object.keys(delta.upserts[0] ?? {}).sort(), [
      "assignee_id",
      "done",
      "id",
      "manual_progress",
      "parent_id",
      "priority",
      "progress",
      "status",
      "title",
      "version",
    ]);
  });

  it("carries who wrote it and when once the result says (m04.02 2.4)", () => {
    const editor = { id: 7, name: "Ada", username: "ada" };
    const delta = deltaFromOpResult(
      result({ updated_by: editor, updated_at: "2026-09-17T14:05:00Z" }),
    );
    assert.deepEqual(delta.upserts[0]?.updated_by, editor);
    assert.equal(delta.upserts[0]?.updated_at, "2026-09-17T14:05:00Z");
    const next = ok(applyDelta(base(), delta).model);
    assert.deepEqual(next.tasks[11]?.updated_by, editor);
    assert.equal(next.tasks[11]?.updated_at, "2026-09-17T14:05:00Z");
  });
});

describe("applyDelta from an op result", () => {
  it("patches the record and leaves the fields it does not carry alone", () => {
    const model = base();
    const before = model.tasks[11];

    const { model: next, affected } = applyDelta(model, deltaFromOpResult(result({ title: "Handles" })));

    assert.equal(next.tasks[11]?.title, "Handles");
    assert.equal(next.tasks[11]?.index, before?.index, "the label was not in the result");
    assert.equal(next.tasks[11]?.comment_count, before?.comment_count);
    assert.ok(affected.includes(11));
  });

  it("moves a task whose parent changed, appending when no slot is known", () => {
    const { model } = applyDelta(base(), deltaFromOpResult(result({ parent_id: 20 })));

    assert.deepEqual([...(ok(model).childIds[20] ?? [])], [11]);
    assert.deepEqual([...(model.childIds[10] ?? [])], [12]);
    assert.equal(model.tasks[11]?.index, "2.1");
    assert.equal(model.tasks[12]?.index, "1.1");
  });

  it("re-sorts a branch's children when the delta changes its sort rule", () => {
    const model = fromSnapshot(
      buildTree([
        {
          id: 10,
          title: "Cabinets",
          children: [{ id: 11, title: "Doors" }, { id: 12, title: "Brackets" }],
        },
      ]),
    );

    const { model: next, affected } = applyDelta(model, {
      upserts: [{ id: 10, sort_mode: "alphabetical", sort_reverse: false }],
      removed: [],
    });

    assert.deepEqual([...(ok(next).childIds[10] ?? [])], [12, 11]);
    assert.equal(next.tasks[12]?.index, "1.1");
    assert.ok(affected.includes(11) && affected.includes(12));

    // The same rule again is not a change, so the order is not touched.
    const again = applyDelta(next, { upserts: [{ id: 10, sort_mode: "alphabetical", sort_reverse: false }], removed: [] });
    assert.deepEqual([...(again.model.childIds[10] ?? [])], [12, 11]);
  });

  it("lands an added row where a sorted parent puts it, not at the slot asked for (7.19)", () => {
    const model = fromSnapshot(
      buildTree([
        {
          id: 10,
          title: "Cabinets",
          sort_mode: "alphabetical",
          children: [{ id: 11, title: "Brackets" }, { id: 12, title: "Doors" }],
        },
      ]),
    );

    const { model: next } = applyDelta(model, {
      upserts: [{ id: 13, parent_id: 10, title: "Catches", position: 0 }],
      removed: [],
    });

    assert.deepEqual([...(ok(next).childIds[10] ?? [])], [11, 13, 12]);
    assert.equal(next.tasks[13]?.index, "1.2");
  });

  it("leaves records it did not mention with their identity", () => {
    const model = base();
    const { model: next } = applyDelta(model, deltaFromOpResult(result({ title: "Handles" })));
    assert.equal(next.tasks[20], model.tasks[20]);
  });

  it("creates a task the model has never seen", () => {
    const { model } = applyDelta(
      base(),
      deltaFromOpResult(result({ id: 99, parent_id: 10, title: "New" })),
    );

    assert.equal(model.tasks[99]?.title, "New");
    assert.deepEqual([...(ok(model).childIds[10] ?? [])], [11, 12, 99]);
  });

  it("is idempotent — the same delta twice is the same model", () => {
    const delta = deltaFromOpResult(result({ parent_id: 20, title: "Handles" }));
    const once = applyDelta(base(), delta).model;
    const twice = applyDelta(once, delta);

    assert.equal(twice.model, once, "a replay rebuilt the model");
    assert.deepEqual(twice.affected, []);
  });
});

describe("applyDelta from a history result", () => {
  const history = (over: Partial<HistoryResult> = {}): HistoryResult => ({
    action: "undo",
    kind: "reordered",
    upserts: [],
    removed: [],
    refetch: false,
    ...over,
  });

  it("puts a reversed reorder back in the slot the server names", () => {
    const delta = deltaFromHistoryResult(
      history({
        upserts: [
          { ...result({ id: 12, title: "Task 12" }), position: 0, description: null },
          { ...result({ id: 11 }), position: 1, description: null },
        ],
      }),
    );

    const { model } = applyDelta(base(), delta);

    assert.deepEqual([...(ok(model).childIds[10] ?? [])], [12, 11]);
    assert.equal(model.tasks[12]?.index, "1.1");
  });

  it("carries description, which the ordinary op result does not", () => {
    const delta = deltaFromHistoryResult(
      history({
        kind: "description_changed",
        upserts: [{ ...result(), position: 0, description: "the old words" }],
      }),
    );

    const { model } = applyDelta(base(), delta);
    assert.equal(model.tasks[11]?.description, "the old words");
  });

  it("takes a whole subtree out on a removal", () => {
    const { model } = applyDelta(base(), deltaFromHistoryResult(history({ removed: [10] })));

    assert.equal(model.tasks[10], undefined);
    assert.equal(model.tasks[11], undefined);
    assert.equal(model.tasks[12], undefined);
    assert.deepEqual([...(ok(model).childIds[model.rootId] ?? [])], [20]);
  });

  it("reports the refetch rather than acting on it", () => {
    const delta = deltaFromHistoryResult(history({ kind: "commented", refetch: true }));
    assert.deepEqual(delta, { upserts: [], removed: [] });
  });
});

describe("deltaFromSnapshot", () => {
  it("expresses a whole re-read as upserts plus the header", () => {
    const tree = buildTree([{ id: 10, children: [{ id: 11 }] }]);
    const delta = deltaFromSnapshot(tree);

    assert.deepEqual(delta.upserts.map((upsert) => upsert.id), [10, 11]);
    assert.equal(delta.initiative?.name, "Kitchen");
    assert.deepEqual(delta.removed, []);
  });

  it("removes what the re-read no longer has, when given the model it replaces", () => {
    const model = base();
    const delta = deltaFromSnapshot(buildTree([{ id: 10 }]), model);

    assert.deepEqual(delta.removed.sort((a, b) => a - b), [11, 12, 20]);

    const { model: next } = applyDelta(model, delta);
    assert.deepEqual([...(ok(next).childIds[next.rootId] ?? [])], [10]);
  });

  it("throws on a snapshot that cannot be a tree, rather than looking empty", () => {
    const tree = buildTree([{ id: 10 }]);
    (tree.tasks[0] as { parent_id: number }).parent_id = 77;
    assert.throws(() => deltaFromSnapshot(tree), InvalidTreeError);
  });

  it("lands a re-read onto a diverged model, and stays put on a replay", () => {
    const model = base();
    const tree = buildTree([{ id: 20 }, { id: 10, children: [{ id: 12 }, { id: 11 }] }]);
    const delta = deltaFromSnapshot(tree, model);

    const once = applyDelta(model, delta).model;
    assert.deepEqual([...(ok(once).childIds[once.rootId] ?? [])], [20, 10]);
    assert.deepEqual([...(once.childIds[10] ?? [])], [12, 11]);

    assert.equal(applyDelta(once, delta).model, once, "a replay rebuilt the model");
  });
});

describe("the header", () => {
  it("takes the Initiative fields a delta carries", () => {
    const { model } = applyDelta(base(), {
      upserts: [],
      removed: [],
      initiative: { name: "Renamed", progress: 88 },
    });

    assert.equal(model.header.name, "Renamed");
    assert.equal(model.header.progress, 88);
    assert.equal(model.header.role, "owner", "the fields it did not carry stayed");
  });
});

describe("roll-ups after a delta (m04.02 item 7.13.1)", () => {
  // Deep › Mid › (Leaf A, Leaf B); Other › Leaf C. Every leaf open.
  const deep = () =>
    fromSnapshot(
      buildTree([
        { id: 31, title: "Deep", children: [{ id: 32, title: "Mid", children: [{ id: 33, title: "Leaf A" }, { id: 34, title: "Leaf B" }] }] },
        { id: 35, title: "Other", children: [{ id: 36, title: "Leaf C" }] },
      ]),
    );

  it("a leaf completion moves its parent and grandparent to the right number", () => {
    const { model, affected } = applyDelta(
      deep(),
      deltaFromOpResult(result({ id: 33, parent_id: 32, status: "done", done: true, progress: 100 })),
    );
    assert.equal(model.tasks[33]?.progress, 100);
    assert.equal(model.tasks[32]?.progress, 50);
    assert.equal(model.tasks[31]?.progress, 50);
    assert.equal(model.tasks[35]?.progress, 0);
    assert.ok(affected.includes(32) && affected.includes(31));
    // Leaf average over the whole Initiative: A done, B and C open.
    assert.equal(ok(model).header.progress, 33);
  });

  it("a removal moves the parent it left", () => {
    const done = applyDelta(deep(), deltaFromOpResult(result({ id: 33, parent_id: 32, status: "done", done: true, progress: 100 }))).model;
    const { model } = applyDelta(done, deltaFromHistoryResult({ action: "redo", kind: "deleted", upserts: [], removed: [34], refetch: false }));
    assert.equal(model.tasks[34], undefined);
    assert.equal(model.tasks[32]?.progress, 100);
    assert.equal(ok(model).tasks[31]?.progress, 100);
  });

  it("a task moved between parents moves both chains", () => {
    const done = applyDelta(deep(), deltaFromOpResult(result({ id: 33, parent_id: 32, status: "done", done: true, progress: 100 }))).model;
    const { model } = applyDelta(done, deltaFromOpResult(result({ id: 33, parent_id: 35, status: "done", done: true, progress: 100 })));
    assert.equal(model.tasks[32]?.progress, 0);
    assert.equal(model.tasks[31]?.progress, 0);
    assert.equal(ok(model).tasks[35]?.progress, 50);
  });

  it("keeps the server's number on a branch the same delta carries", () => {
    const { model } = applyDelta(deep(), {
      upserts: [
        { id: 33, status: "done", progress: 100 },
        { id: 32, progress: 42 },
      ],
      removed: [],
    });
    assert.equal(model.tasks[32]?.progress, 42);
    // "Deep" is not carried, so it is recomputed — over its leaves, not its child's number.
    assert.equal(ok(model).tasks[31]?.progress, 50);
  });
});
