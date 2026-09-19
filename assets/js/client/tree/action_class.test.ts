import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { ActionKind } from "./action_class.ts";
import { NOT_AVAILABLE_OFFLINE, actionClass, availableOffline, unavailableLabel } from "./action_class.ts";

const QUEUEABLE: readonly ActionKind[] = [
  "edit",
  "add",
  "toggleComplete",
  "cascadeComplete",
  "reorder",
  "indent",
  "outdent",
  "step",
  "move",
  "delete",
  "coAssignees",
  "setSort",
  "cascadeSort",
  "editInitiative",
];

const NEEDS_SERVER: readonly ActionKind[] = [
  "undo",
  "redo",
  "manageMembers",
  "import",
  "history",
  "activity",
  "comments",
  "signIn",
  "signOut",
];

describe("which actions may be queued offline (m04.03 5.3)", () => {
  it("queues everything that carries a stable id and can rebase later", () => {
    for (const kind of QUEUEABLE) assert.equal(actionClass(kind), "queueable", kind);
  });

  it("needs the server for the stack, membership, imports, reads and the session", () => {
    for (const kind of NEEDS_SERVER) assert.equal(actionClass(kind), "needs-server", kind);
  });

  it("lets a queueable action through offline and holds a server-gated one", () => {
    assert.equal(availableOffline("edit", true), true);
    assert.equal(availableOffline("undo", true), false);
    assert.equal(availableOffline("undo", false), true, "online, everything is available");
  });

  it("keeps the control's own name and adds the reason", () => {
    assert.equal(unavailableLabel("Undo"), "Undo — not available offline");
    assert.equal(NOT_AVAILABLE_OFFLINE, "Not available offline");
  });
});
