import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { InitiativeHeader, TreeModel } from "../tree/model.ts";
import { fromSnapshot } from "../tree/model.ts";
import {
  EDIT_NAME_LABEL,
  EDIT_NAME_TITLE,
  EDIT_SUBTITLE_TITLE,
  adoptHeaderReply,
  headerCounts,
  headerEdit,
  revertHeader,
} from "./initiative_header_model.ts";

const header: InitiativeHeader = {
  id: 7,
  name: "Garden",
  subtitle: "The back plot",
  role: "owner",
  progress: 50,
  unit_count: 3,
  version: 4,
};

function tree(): TreeModel {
  return fromSnapshot({
    id: 7,
    name: "Garden",
    subtitle: "The back plot",
    role: "owner",
    progress: 50,
    progress_calc: "leaf",
    unit_count: 3,
    index_style: "none",
    root_task_id: 1,
    version: 4,
    tasks: [
      {
        id: 10,
        parent_id: 1,
        title: "Beds",
        status: "open",
        progress: 50,
        position: 0,
        children: [
          { id: 11, parent_id: 10, title: "Dig", status: "done", progress: 100, position: 0, children: [] },
          { id: 12, parent_id: 10, title: "Sow", status: "open", progress: 0, position: 1, children: [] },
        ],
      },
      { id: 13, parent_id: 1, title: "Fence", status: "open", progress: 0, position: 1, children: [] },
    ],
  } as never);
}

describe("the Initiative header (m04.02 item 7.10)", () => {
  it("keeps the workspace's words", () => {
    assert.equal(EDIT_NAME_LABEL, "Edit initiative name");
    assert.equal(EDIT_NAME_TITLE, "Edit name");
    assert.equal(EDIT_SUBTITLE_TITLE, "Click to edit");
  });

  it("counts the root's units and how many are done, as the badge shows them", () => {
    assert.deepEqual(headerCounts(tree()), { total: 3, done: 1 });
  });

  describe("a click-to-edit write", () => {
    it("sends the new name against the version it was read at, and shows it at once", () => {
      const edit = headerEdit(header, { name: "  Orchard " });
      assert.ok(edit);
      assert.deepEqual(edit.request, {
        operations: [
          { op: "update", type: "initiative", id: 7, data: { name: "Orchard", expected_version: 4 } },
        ],
      });
      assert.equal(edit.next.name, "Orchard");
      assert.equal(edit.next.subtitle, "The back plot");
    });

    it("sends nothing for a name that did not change, or a blank one", () => {
      assert.equal(headerEdit(header, { name: "Garden" }), null);
      assert.equal(headerEdit(header, { name: "   " }), null);
    });

    it("clears the subtitle with an empty string and holds none as null", () => {
      const edit = headerEdit(header, { subtitle: " " });
      assert.ok(edit);
      assert.deepEqual(edit.request.operations[0].data, { subtitle: "", expected_version: 4 });
      assert.equal(edit.next.subtitle, null);
      assert.equal(headerEdit({ ...header, subtitle: null }, { subtitle: "" }), null);
    });
  });

  describe("the reply", () => {
    it("lands the name and version the server confirmed", () => {
      const landed = adoptHeaderReply(header, {
        results: [{ id: 7, type: "initiative", data: { name: "Orchard", version: 5 } }],
      });
      assert.equal(landed.name, "Orchard");
      assert.equal(landed.version, 5);
      assert.equal(landed.subtitle, "The back plot");
    });

    it("leaves the header alone when it cannot be read", () => {
      assert.equal(adoptHeaderReply(header, null), header);
      assert.equal(adoptHeaderReply(header, { results: [] }), header);
      assert.equal(adoptHeaderReply(header, { results: [{ type: "task" }] }), header);
    });
  });

  it("puts back only what a refused edit changed", () => {
    const predicted = { ...header, name: "Orchard", version: 9 };
    const back = revertHeader(predicted, header, { name: "Orchard" });
    assert.equal(back.name, "Garden");
    assert.equal(back.version, 9);
    assert.equal(back.subtitle, "The back plot");
  });
});
