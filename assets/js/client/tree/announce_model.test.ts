import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { fromSnapshot } from "./model.ts";
import {
  NOTHING_SELECTED,
  announcementFor,
  collapseAnnouncement,
  selectionAnnouncement,
} from "./announce_model.ts";

const model = fromSnapshot({
  id: 7,
  name: "Garden",
  subtitle: null,
  role: "owner",
  progress: 0,
  progress_calc: "leaf",
  unit_count: 3,
  index_style: "none",
  root_task_id: 1,
  version: 1,
  tasks: [
    {
      id: 10,
      parent_id: 1,
      title: "Bravo",
      status: "open",
      progress: 0,
      position: 0,
      children: [
        { id: 11, parent_id: 10, title: "Charlie", status: "open", progress: 0, position: 0, children: [] },
        { id: 12, parent_id: 10, title: "Echo", status: "open", progress: 0, position: 1, children: [] },
      ],
    },
    { id: 13, parent_id: 1, title: "Delta", status: "open", progress: 0, position: 1, children: [] },
  ],
} as never);

describe("what the tree tells a screen reader (m04.02 item 7.12)", () => {
  it("says which row is selected, how deep it sits and where among its siblings", () => {
    assert.equal(selectionAnnouncement(model, 10), "Selected Bravo, level 1, 1 of 2");
    assert.equal(selectionAnnouncement(model, 12), "Selected Echo, level 2, 2 of 2");
  });

  it("says when nothing is selected, and nothing for a row it does not know", () => {
    assert.equal(selectionAnnouncement(model, null), NOTHING_SELECTED);
    assert.equal(selectionAnnouncement(model, 99), null);
  });

  it("names a branch that closed or opened, and stays quiet otherwise", () => {
    const open = new Set<number>();
    const shut = new Set([10]);
    assert.equal(collapseAnnouncement(model, open, shut), "Bravo collapsed");
    assert.equal(collapseAnnouncement(model, shut, open), "Bravo expanded");
    assert.equal(collapseAnnouncement(model, shut, new Set([10])), null);
  });

  it("lets a selection change speak over the branches a reveal opened for it", () => {
    const before = { selectedId: null, collapsedIds: new Set([10]) };
    const after = { selectedId: 11, collapsedIds: new Set<number>() };
    assert.equal(announcementFor(model, before, after), "Selected Charlie, level 2, 1 of 2");
    assert.equal(announcementFor(model, after, { ...after, collapsedIds: new Set([10]) }), "Bravo collapsed");
    assert.equal(announcementFor(model, after, after), null);
  });
});
