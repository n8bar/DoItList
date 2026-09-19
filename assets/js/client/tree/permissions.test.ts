import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

import { canProgress, permissionsFor, permitsWrite } from "./permissions.ts";

describe("what a role may do", () => {
  it("lets an owner edit and administer", () => {
    const owner = permissionsFor("owner");
    assert.equal(owner.canEdit, true);
    assert.equal(owner.canAdmin, true);
  });

  it("lets an editor edit but not administer", () => {
    const editor = permissionsFor("editor");
    assert.equal(editor.canEdit, true);
    assert.equal(editor.canAdmin, false);
  });

  it("lets a viewer do neither", () => {
    const viewer = permissionsFor("viewer");
    assert.equal(viewer.canEdit, false);
    assert.equal(viewer.canAdmin, false);
  });

  it("reads a missing or unknown role as the least powerful thing", () => {
    for (const role of [null, undefined]) {
      const none = permissionsFor(role);
      assert.equal(none.canEdit, false);
      assert.equal(none.canAdmin, false);
      assert.equal(none.viewerPlus, false);
    }
  });

  it("matches the roles Initiatives.can_edit?/1 and can_admin?/1 accept", () => {
    const source = readFileSync(new URL("../../../../lib/doit/initiatives.ex", import.meta.url), "utf8");
    assert.match(source, /def can_edit\?\(role\) when role in ~w\(owner editor\)/);
    assert.match(source, /def can_admin\?\("owner"\)/);
  });
});

describe("viewer+", () => {
  it("is off unless the Initiative has it on and the member is a viewer", () => {
    assert.equal(permissionsFor("viewer", { enabled: false }).viewerPlus, false);
    assert.equal(permissionsFor("editor", { enabled: true }).viewerPlus, false);
    assert.equal(permissionsFor("viewer", { enabled: true }).viewerPlus, true);
  });

  it("lets a viewer+ move Progress on a task they lead, and nothing else", () => {
    const viewerPlus = permissionsFor("viewer", { enabled: true, ledTaskIds: [7, 9] });

    assert.equal(canProgress(viewerPlus, 7), true);
    assert.equal(canProgress(viewerPlus, 9), true);
    assert.equal(canProgress(viewerPlus, 8), false);
    // Still not an editor: leading a task is not permission to change it.
    assert.equal(viewerPlus.canEdit, false);
  });

  it("carries no led ids when viewer+ is off, however many were handed in", () => {
    const viewer = permissionsFor("viewer", { enabled: false, ledTaskIds: [7] });
    assert.equal(viewer.ledTaskIds.size, 0);
    assert.equal(canProgress(viewer, 7), false);
  });

  it("lets anyone who can edit move any task's Progress", () => {
    const editor = permissionsFor("editor");
    assert.equal(canProgress(editor, 1), true);
    assert.equal(canProgress(editor, 99), true);
  });
});

describe("what a role may send (m04.03 4.7)", () => {
  const title = { kind: "edit", id: 11, fields: { title: "x" } } as const;
  const progress = { kind: "edit", id: 11, fields: { manual_progress: 40 } } as const;
  const done = { kind: "toggleComplete", id: 11, done: true } as const;
  const move = { kind: "reorder", id: 11, dir: "up" } as const;

  it("an editor may send anything; a viewer nothing", () => {
    const editor = permissionsFor("editor");
    const viewer = permissionsFor("viewer");
    for (const write of [title, progress, done, move, null]) {
      assert.equal(permitsWrite(editor, write), true);
      assert.equal(permitsWrite(viewer, write), false);
    }
  });

  it("a viewer+ may move the Progress of a task they lead, and nothing else", () => {
    const led = permissionsFor("viewer", { enabled: true, ledTaskIds: [11] });
    assert.equal(permitsWrite(led, progress), true);
    assert.equal(permitsWrite(led, done), true);
    assert.equal(permitsWrite(led, title), false);
    assert.equal(permitsWrite(led, move), false);
    assert.equal(permitsWrite(led, { ...done, id: 12 }), false);
    assert.equal(permitsWrite(led, { kind: "edit", id: 11, fields: { manual_progress: 40, title: "x" } }), false);
  });
});
