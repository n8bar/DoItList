import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { dialogIds, outcomeFor, restoreFocus } from "./dialog_model.ts";

describe("dialog wiring (guardrails §3.1, §4.1)", () => {
  it("derives every id a dialog needs from its one id", () => {
    const ids = dialogIds("remove-task");

    assert.equal(ids.titleId, "remove-task-title");
    assert.equal(ids.descriptionId, "remove-task-description");
    assert.equal(ids.cancelId, "remove-task-cancel");
    assert.equal(ids.confirmId, "remove-task-confirm");
    assert.equal(new Set(Object.values(ids)).size, 4, "the ids must all differ");
  });

  it("treats every way out except the confirm button as a cancel", () => {
    assert.equal(outcomeFor("confirm"), "confirm");
    assert.equal(outcomeFor("escape"), "cancel");
    assert.equal(outcomeFor("cancel"), "cancel");
    assert.equal(outcomeFor("backdrop"), "cancel");
  });
});

describe("giving focus back when the dialog closes (§3.1)", () => {
  const opener = (isConnected: boolean) => {
    let focused = 0;
    return {
      element: {
        isConnected,
        focus() {
          focused += 1;
        },
      },
      focused: () => focused,
    };
  };

  it("focuses the opener", () => {
    const trigger = opener(true);
    assert.equal(restoreFocus(trigger.element), true);
    assert.equal(trigger.focused(), 1);
  });

  it("does nothing when there was no opener", () => {
    assert.equal(restoreFocus(null), false);
  });

  it("does not focus an opener that has left the document", () => {
    const trigger = opener(false);
    assert.equal(restoreFocus(trigger.element), false);
    assert.equal(trigger.focused(), 0);
  });
});
