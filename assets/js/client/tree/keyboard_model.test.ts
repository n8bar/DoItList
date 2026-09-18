import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

import { buildTree } from "./gen.ts";
import { fromSnapshot } from "./model.ts";
import type { KeyboardState } from "./keyboard_model.ts";
import {
  SHORTCUTS,
  blockedMove,
  handleKey,
  navTarget,
  nextIdclipBuffer,
} from "./keyboard_model.ts";
import { visibleRows } from "./tree_model.ts";

//  10 Cabinets
//    11
//    12
//      13
//  20 Worktop
const model = fromSnapshot(
  buildTree([{ id: 10, children: [{ id: 11 }, { id: 12, children: [{ id: 13 }] }] }, { id: 20 }], {
    rootTaskId: 99,
  }),
);

const state = (
  selectedId: number | null,
  options: { lastId?: number | null; closed?: number[] } = {},
): KeyboardState => {
  const closed = options.closed ?? [];
  return {
    model,
    visible: visibleRows(model, (id) => closed.includes(id)),
    selectedId,
    lastId: options.lastId ?? null,
  };
};

describe("arrow selection", () => {
  const visible = visibleRows(model, () => false);

  it("steps down and up through the rows on screen", () => {
    assert.equal(navTarget(visible, 10, "ArrowDown"), 11);
    assert.equal(navTarget(visible, 11, "ArrowDown"), 12);
    assert.equal(navTarget(visible, 12, "ArrowDown"), 13);
    assert.equal(navTarget(visible, 13, "ArrowDown"), 20);
    assert.equal(navTarget(visible, 20, "ArrowUp"), 13);
  });

  it("stops at the ends rather than wrapping", () => {
    assert.equal(navTarget(visible, 10, "ArrowUp"), null);
    assert.equal(navTarget(visible, 20, "ArrowDown"), null);
  });

  it("goes to the parent on left and the first child on right", () => {
    assert.equal(navTarget(visible, 13, "ArrowLeft"), 12);
    assert.equal(navTarget(visible, 12, "ArrowLeft"), 10);
    assert.equal(navTarget(visible, 10, "ArrowLeft"), null);
    assert.equal(navTarget(visible, 10, "ArrowRight"), 11);
    assert.equal(navTarget(visible, 11, "ArrowRight"), null);
  });

  it("skips what a collapsed branch hides, in both directions", () => {
    const folded = visibleRows(model, (id) => id === 12);
    assert.equal(navTarget(folded, 12, "ArrowDown"), 20);
    assert.equal(navTarget(folded, 20, "ArrowUp"), 12);
    // A collapsed branch has no first child on screen to move into.
    assert.equal(navTarget(folded, 12, "ArrowRight"), null);
  });

  it("drives the selection, instantly and without a network answer", () => {
    assert.deepEqual(handleKey(state(10), "ArrowDown"), { kind: "select", id: 11 });
    assert.deepEqual(handleKey(state(10), "ArrowUp"), { kind: "none" });
  });

  it("does nothing at all when nothing is selected", () => {
    for (const key of ["ArrowDown", "ArrowLeft", " ", "n", "S", "Delete", "p"]) {
      assert.deepEqual(handleKey(state(null), key), { kind: "none" }, key);
    }
  });
});

describe("Home and End", () => {
  it("select the first and last rows on screen", () => {
    assert.deepEqual(handleKey(state(13), "Home"), { kind: "select", id: 10 });
    assert.deepEqual(handleKey(state(10), "End"), { kind: "select", id: 20 });
  });

  it("work without a selection, and do nothing in an empty tree", () => {
    assert.deepEqual(handleKey(state(null), "Home"), { kind: "select", id: 10 });
    const empty: KeyboardState = { model, visible: [], selectedId: null, lastId: null };
    assert.deepEqual(handleKey(empty, "End"), { kind: "none" });
  });
});

describe("Enter and Escape", () => {
  it("Enter closes an open selection", () => {
    assert.deepEqual(handleKey(state(12), "Enter"), { kind: "select", id: null });
  });

  it("Enter reopens the last task, or falls back to the first row", () => {
    assert.deepEqual(handleKey(state(null, { lastId: 13 }), "Enter"), { kind: "select", id: 13 });
    assert.deepEqual(handleKey(state(null), "Enter"), { kind: "select", id: 10 });
  });

  it("Escape clears the selection, and is otherwise the browser's", () => {
    assert.deepEqual(handleKey(state(12), "Escape"), { kind: "select", id: null });
    assert.deepEqual(handleKey(state(null), "Escape"), { kind: "none" });
  });
});

describe("Space", () => {
  it("expands or collapses the selected task", () => {
    assert.deepEqual(handleKey(state(10), " "), { kind: "toggleCollapse", id: 10 });
  });
});

describe("Alt + arrows", () => {
  it("asks for a reorder up or down", () => {
    assert.deepEqual(handleKey(state(12), "ArrowUp", { alt: true }), {
      kind: "intent",
      intent: { kind: "reorder", id: 12, dir: "up" },
    });
    assert.deepEqual(handleKey(state(11), "ArrowDown", { alt: true }), {
      kind: "intent",
      intent: { kind: "reorder", id: 11, dir: "down" },
    });
  });

  it("asks for an indent on right and an outdent on left", () => {
    assert.deepEqual(handleKey(state(12), "ArrowRight", { alt: true }), {
      kind: "intent",
      intent: { kind: "indent", id: 12 },
    });
    assert.deepEqual(handleKey(state(13), "ArrowLeft", { alt: true }), {
      kind: "intent",
      intent: { kind: "outdent", id: 13 },
    });
  });

  it("refuses the four impossible moves, audibly", () => {
    // First child up, last child down, top-level dedent, indent with no
    // previous sibling.
    assert.equal(blockedMove(model, 11, "ArrowUp"), true);
    assert.equal(blockedMove(model, 12, "ArrowDown"), true);
    assert.equal(blockedMove(model, 10, "ArrowLeft"), true);
    assert.equal(blockedMove(model, 11, "ArrowRight"), true);

    assert.deepEqual(handleKey(state(11), "ArrowUp", { alt: true }), { kind: "blocked" });
    assert.deepEqual(handleKey(state(10), "ArrowLeft", { alt: true }), { kind: "blocked" });
  });

  it("allows the four that are possible", () => {
    assert.equal(blockedMove(model, 12, "ArrowUp"), false);
    assert.equal(blockedMove(model, 11, "ArrowDown"), false);
    assert.equal(blockedMove(model, 13, "ArrowLeft"), false);
    assert.equal(blockedMove(model, 12, "ArrowRight"), false);
  });

  it("refuses a move on a task the model does not hold", () => {
    assert.equal(blockedMove(model, 404, "ArrowUp"), true);
  });
});

describe("N and S", () => {
  it("open the add form as a subtask or as a sibling", () => {
    assert.deepEqual(handleKey(state(12), "n"), {
      kind: "openAdd",
      anchor: { kind: "child", taskId: 12 },
    });
    assert.deepEqual(handleKey(state(12), "S"), {
      kind: "openAdd",
      anchor: { kind: "sibling", taskId: 12 },
    });
  });
});

describe("P and A", () => {
  it("step the value forward, and back with Shift", () => {
    assert.deepEqual(handleKey(state(12), "p"), {
      kind: "intent",
      intent: { kind: "step", id: 12, field: "priority", back: false },
    });
    assert.deepEqual(handleKey(state(12), "A", { shift: true }), {
      kind: "intent",
      intent: { kind: "step", id: 12, field: "assignee", back: true },
    });
  });

  it("put the cursor in the field when Alt is held", () => {
    assert.deepEqual(handleKey(state(12), "p", { alt: true }), {
      kind: "focusField",
      field: "priority",
    });
    assert.deepEqual(handleKey(state(12), "a", { alt: true }), {
      kind: "focusField",
      field: "assignee",
    });
  });
});

describe("Del and ?", () => {
  it("asks to delete the selected task", () => {
    assert.deepEqual(handleKey(state(12), "Delete"), {
      kind: "intent",
      intent: { kind: "delete", id: 12 },
    });
  });

  it("shows the help, selection or no selection", () => {
    assert.deepEqual(handleKey(state(null), "?"), { kind: "shortcuts" });
    assert.deepEqual(handleKey(state(12), "?"), { kind: "shortcuts" });
  });
});

describe("undo and redo", () => {
  it("Ctrl or Cmd + Z undoes, with or without a selection", () => {
    assert.deepEqual(handleKey(state(12), "z", { ctrl: true }), { kind: "history", action: "undo" });
    assert.deepEqual(handleKey(state(null), "Z", { meta: true }), { kind: "history", action: "undo" });
  });

  it("Shift, or Y, makes it a redo", () => {
    assert.deepEqual(handleKey(state(12), "z", { ctrl: true, shift: true }), {
      kind: "history",
      action: "redo",
    });
    assert.deepEqual(handleKey(state(12), "y", { meta: true }), { kind: "history", action: "redo" });
  });

  it("a bare z or y is not a chord", () => {
    assert.deepEqual(handleKey(state(12), "z"), { kind: "none" });
    assert.deepEqual(handleKey(state(12), "y"), { kind: "none" });
  });
});

describe("keys that are not the tree's", () => {
  it("leaves a browser or system chord alone", () => {
    assert.deepEqual(handleKey(state(12), "c", { ctrl: true }), { kind: "none" });
    assert.deepEqual(handleKey(state(12), "ArrowDown", { meta: true }), { kind: "none" });
    assert.deepEqual(handleKey(state(12), "q"), { kind: "none" });
  });
});

describe("idclip", () => {
  it("fires on the whole word and resets afterwards", () => {
    let buffer = "";
    let fired = false;
    for (const key of "idclip") {
      const step = nextIdclipBuffer(buffer, key);
      buffer = step.buffer;
      fired = step.triggered;
    }
    assert.equal(fired, true);
    assert.equal(buffer, "");
  });

  it("keeps only the last six letters, and ignores everything else", () => {
    assert.deepEqual(nextIdclipBuffer("abcdef", "g"), { buffer: "bcdefg", triggered: false });
    assert.deepEqual(nextIdclipBuffer("idcli", "Enter"), { buffer: "idcli", triggered: false });
    assert.deepEqual(nextIdclipBuffer("idcli", "4"), { buffer: "idcli", triggered: false });
  });
});

describe("the help overlay's list", () => {
  it("is the LiveView's @shortcuts, word for word", () => {
    const source = readFileSync(
      new URL("../../../../lib/doit_web/components/core_components.ex", import.meta.url),
      "utf8",
    );
    for (const [keys, label] of SHORTCUTS) {
      assert.ok(
        source.includes(`{"${keys}", "${label}"}`),
        `core_components.ex no longer lists ${keys}`,
      );
    }
    assert.equal(SHORTCUTS.length, (source.match(/^    \{"[^"]+", "[^"]+"\},?$/gm) ?? []).length);
  });
});
