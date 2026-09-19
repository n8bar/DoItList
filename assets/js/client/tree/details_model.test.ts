import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { Member } from "../api/types.ts";
import {
  PRIORITIES,
  SORT_MODE_OPTIONS,
  addCoAssignee,
  assigneeEdit,
  assigneeOptions,
  coAssigneeOptions,
  coRows,
  descriptionEdit,
  editingNotice,
  fieldsFor,
  inheritLabel,
  isLeaf,
  moveCoAssignee,
  priorityEdit,
  progressEdit,
  progressView,
  removeCoAssignee,
  reverseDisabled,
  sortEdit,
  sortModeFrom,
  sortModeLabel,
  titleEdit,
  updatedAtText,
  updatedTitleText,
} from "./details_model.ts";
import { buildTree } from "./gen.ts";
import { fromSnapshot } from "./model.ts";
import { permissionsFor } from "./permissions.ts";
import { memberIndex } from "./row_model.ts";

const model = () =>
  fromSnapshot(
    buildTree([
      {
        id: 10,
        title: "Cabinets",
        progress: 75,
        sort_mode: "priority",
        sort_reverse: true,
        children: [
          {
            id: 11,
            title: "Doors",
            description: "Oak",
            manual_progress: 50,
            priority: "high",
            assignee_id: 1,
            co_assignee_ids: [2, 3, 9],
          },
          { id: 12, status: "done", children: [{ id: 13 }] },
        ],
      },
      { id: 20, title: "Top level" },
    ]),
  );

const memberList: Member[] = [
  { user_id: 1, role: "owner", name: "Ann Able", username: "ann" },
  { user_id: 2, role: "editor", name: "Bo Baker", username: "bo" },
  { user_id: 3, role: "viewer", name: null, username: "cy" },
  { user_id: 4, role: "viewer", name: "Di Dorn", username: "di" },
];
const members = memberIndex(memberList);

const record = (id: number) => {
  const found = model().tasks[id];
  assert.ok(found, `task ${id}`);
  return found;
};

const editor = permissionsFor("editor");
const viewer = permissionsFor("viewer");
const viewerPlus = permissionsFor("viewer", { enabled: true, ledTaskIds: [11] });

describe("which fields are enabled", () => {
  it("lets an editor use everything on a leaf", () => {
    const fields = fieldsFor(model(), record(11), editor);
    assert.deepEqual(fields, { edit: true, assignee: true, progress: true, coAssignees: true });
  });

  it("disables progress on a branch, even for an editor", () => {
    assert.equal(fieldsFor(model(), record(10), editor).progress, false);
    assert.equal(isLeaf(model(), 10), false);
    assert.equal(isLeaf(model(), 11), true);
  });

  it("shows a viewer everything disabled, and no co-assignee block when there are none", () => {
    assert.deepEqual(fieldsFor(model(), record(20), viewer), {
      edit: false,
      assignee: false,
      progress: false,
      coAssignees: false,
    });
    // A task with co-assignees still lists them, read-only.
    assert.equal(fieldsFor(model(), record(11), viewer).coAssignees, true);
  });

  it("lets a viewer+ move progress on a leaf they lead, and nothing else", () => {
    const fields = fieldsFor(model(), record(11), viewerPlus);
    assert.equal(fields.progress, true);
    assert.equal(fields.edit, false);
    assert.equal(fields.assignee, false);
  });
});

describe("the progress block", () => {
  it("reads the leaf's own input", () => {
    const view = progressView(model(), record(11));
    assert.equal(view.leaf, true);
    assert.equal(view.value, 50);
    assert.equal(view.ariaLabel, "Manual progress");
  });

  it("reads the branch's roll-up and says why the slider is off", () => {
    const view = progressView(model(), record(10));
    assert.equal(view.leaf, false);
    assert.equal(view.value, 75);
    assert.equal(view.computed, 75);
    assert.match(view.ariaLabel, /computed from subtasks/);
  });
});

describe("the sort menu", () => {
  it("lists the criteria first and Manual last, each with its label", () => {
    assert.deepEqual(SORT_MODE_OPTIONS, [
      "alphabetical",
      "completion",
      "priority",
      "created",
      "updated",
      "manual",
    ]);
    assert.equal(sortModeLabel("completion"), "Completion %");
    assert.equal(sortModeLabel("created"), "First Created");
  });

  it("names what Inherit resolves to, from the ancestors and not the task itself", () => {
    assert.equal(inheritLabel(model(), 11), "Inherit (lowest priority)");
    assert.equal(inheritLabel(model(), 10), "Inherit (Manual)");
    assert.equal(inheritLabel(model(), 999), "Inherit (Manual)");
  });

  it("disables Reverse on Inherit and Manual", () => {
    assert.equal(reverseDisabled(null), true);
    assert.equal(reverseDisabled("manual"), true);
    assert.equal(reverseDisabled("priority"), false);
  });

  it("reads the select's value back, with blank as Inherit", () => {
    assert.equal(sortModeFrom(""), null);
    assert.equal(sortModeFrom("priority"), "priority");
    assert.equal(sortModeFrom("bogus"), null);
  });

  it("drops a stale Reverse when the mode stops meaning one, and skips no-ops", () => {
    assert.deepEqual(sortEdit(record(10), "manual", true), { mode: "manual", reverse: false });
    assert.deepEqual(sortEdit(record(10), null, true), { mode: null, reverse: false });
    assert.deepEqual(sortEdit(record(10), "alphabetical", true), {
      mode: "alphabetical",
      reverse: true,
    });
    assert.equal(sortEdit(record(10), "priority", true), null);
  });
});

describe("the assignee selects", () => {
  it("offers an editor every member as the primary", () => {
    assert.deepEqual(
      assigneeOptions(members).map((u) => u.username),
      ["ann", "bo", "cy", "di"],
    );
  });

  it("offers as a co-assignee only members who are neither primary nor already listed", () => {
    assert.deepEqual(
      coAssigneeOptions(record(11), members).map((u) => u.id),
      [4],
    );
    assert.deepEqual(
      coAssigneeOptions(record(20), members).map((u) => u.id),
      [1, 2, 3, 4],
    );
  });

  it("lists the co-assignees in order, naming who it can and keeping who it cannot", () => {
    const rows = coRows(record(11), members);
    assert.deepEqual(
      rows.map((r) => [r.id, r.user?.username ?? null, r.first, r.last]),
      [
        [2, "bo", true, false],
        [3, "cy", false, false],
        [9, null, false, true],
      ],
    );
  });
});

describe("co-assignee arithmetic", () => {
  it("swaps a row with its neighbour", () => {
    assert.deepEqual(moveCoAssignee([2, 3, 9], 3, "up"), [3, 2, 9]);
    assert.deepEqual(moveCoAssignee([2, 3, 9], 3, "down"), [2, 9, 3]);
  });

  it("refuses to move past either end, or somebody not listed", () => {
    assert.equal(moveCoAssignee([2, 3, 9], 2, "up"), null);
    assert.equal(moveCoAssignee([2, 3, 9], 9, "down"), null);
    assert.equal(moveCoAssignee([2, 3, 9], 7, "up"), null);
  });

  it("removes, and appends at the end, without touching the input", () => {
    const ids = [2, 3, 9];
    assert.deepEqual(removeCoAssignee(ids, 3), [2, 9]);
    assert.deepEqual(addCoAssignee(ids, 4), [2, 3, 9, 4]);
    assert.deepEqual(addCoAssignee(ids, 3), [2, 3, 9]);
    assert.deepEqual(ids, [2, 3, 9]);
  });
});

describe("what an edit commits", () => {
  it("commits a trimmed title, and nothing for a blank or unchanged one", () => {
    assert.deepEqual(titleEdit(record(11), "  Drawers "), { title: "Drawers" });
    assert.equal(titleEdit(record(11), "   "), null);
    assert.equal(titleEdit(record(11), "Doors"), null);
  });

  it("commits a cleared description as null, and skips a no-op", () => {
    assert.deepEqual(descriptionEdit(record(11), ""), { description: null });
    assert.deepEqual(descriptionEdit(record(11), "Maple"), { description: "Maple" });
    assert.equal(descriptionEdit(record(11), "Oak"), null);
    assert.equal(descriptionEdit(record(20), ""), null);
  });

  it("commits only a real priority that differs", () => {
    assert.deepEqual(PRIORITIES, ["low", "normal", "high"]);
    assert.deepEqual(priorityEdit(record(11), "low"), { priority: "low" });
    assert.equal(priorityEdit(record(11), "high"), null);
    assert.equal(priorityEdit(record(11), "urgent"), null);
  });

  it("reads the assignee select, with blank as unassigned", () => {
    assert.deepEqual(assigneeEdit(record(11), "2"), { assignee_id: 2 });
    assert.deepEqual(assigneeEdit(record(11), ""), { assignee_id: null });
    assert.equal(assigneeEdit(record(11), "1"), null);
    assert.equal(assigneeEdit(record(11), "x"), null);
  });

  it("formats the last-updated time the way <.local_time> does", () => {
    // Built from local components so the expectation holds in any zone.
    const at = new Date(2026, 8, 7, 9, 5, 3).toISOString();
    assert.equal(updatedAtText(at), "Sep 7 09:05");
    assert.equal(updatedTitleText(at), "2026-09-07 09:05:03");
    assert.equal(updatedAtText(null), "");
    assert.equal(updatedAtText("not a date"), "");
    assert.equal(updatedTitleText("not a date"), "");
  });

  it("clamps and snaps the slider, and skips a no-op", () => {
    assert.deepEqual(progressEdit(record(11), "72"), { manual_progress: 70 });
    assert.deepEqual(progressEdit(record(11), "140"), { manual_progress: 100 });
    assert.deepEqual(progressEdit(record(11), "-5"), { manual_progress: 0 });
    assert.equal(progressEdit(record(11), "50"), null);
    assert.equal(progressEdit(record(11), ""), null);
  });
});

describe("who else is in a field (m04.03 4.1.2)", () => {
  it("names one, two, or more; nothing for nobody", () => {
    assert.equal(editingNotice([]), "");
    assert.equal(editingNotice(["Ann"]), "Ann is editing this too.");
    assert.equal(editingNotice(["Ann", "Bob"]), "Ann and Bob are editing this too.");
    assert.equal(editingNotice(["Ann", "Bob", "Cy"]), "Ann, Bob and Cy are editing this too.");
  });
});
