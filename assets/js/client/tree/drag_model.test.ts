import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { buildTree } from "./gen.ts";
import { fromSnapshot } from "./model.ts";
import {
  EDGE_PX,
  bandFor,
  lastChildPosition,
  resolveDrop,
  siblingPosition,
  withinSource,
} from "./drag_model.ts";

//  10 Cabinets
//    11
//    12
//      13
//  20 Worktop
//  30 Sink
const model = fromSnapshot(
  buildTree(
    [{ id: 10, children: [{ id: 11 }, { id: 12, children: [{ id: 13 }] }] }, { id: 20 }, { id: 30 }],
    { rootTaskId: 99 },
  ),
);

describe("bandFor", () => {
  const top = 100;
  const height = 40;

  it("reads the top strip as above", () => {
    assert.equal(bandFor(top, height, top, false), "above");
    assert.equal(bandFor(top, height, top + EDGE_PX - 1, false), "above");
  });

  it("reads the middle as center", () => {
    assert.equal(bandFor(top, height, top + EDGE_PX, false), "center");
    assert.equal(bandFor(top, height, top + height / 2, false), "center");
    assert.equal(bandFor(top, height, top + height - EDGE_PX - 1, false), "center");
  });

  it("reads the bottom strip as below", () => {
    assert.equal(bandFor(top, height, top + height - EDGE_PX, false), "below");
    assert.equal(bandFor(top, height, top + height, false), "below");
  });

  it("gives an expanded branch no below strip", () => {
    assert.equal(bandFor(top, height, top + height - 1, true), "center");
    assert.equal(bandFor(top, height, top, true), "above");
  });
});

describe("siblingPosition", () => {
  it("is the anchor's index for above and one more for below", () => {
    assert.equal(siblingPosition(model, 11, 20, "above"), 1);
    assert.equal(siblingPosition(model, 11, 20, "below"), 2);
    assert.equal(siblingPosition(model, 20, 13, "above"), 0);
    assert.equal(siblingPosition(model, 20, 13, "below"), 1);
  });

  it("shifts down by one when the source sits earlier in the same list", () => {
    assert.equal(siblingPosition(model, 10, 20, "above"), 0);
    assert.equal(siblingPosition(model, 10, 20, "below"), 1);
    assert.equal(siblingPosition(model, 10, 30, "above"), 1);
    assert.equal(siblingPosition(model, 10, 30, "below"), 2);
  });

  it("does not shift when the source sits later in the same list", () => {
    assert.equal(siblingPosition(model, 30, 10, "above"), 0);
    assert.equal(siblingPosition(model, 30, 10, "below"), 1);
    assert.equal(siblingPosition(model, 30, 20, "above"), 1);
    assert.equal(siblingPosition(model, 30, 20, "below"), 2);
  });
});

describe("lastChildPosition", () => {
  it("is the child count, less the source when it is already there", () => {
    assert.equal(lastChildPosition(model, 20, 10), 2);
    assert.equal(lastChildPosition(model, 11, 10), 1);
    assert.equal(lastChildPosition(model, 20, 30), 0);
  });
});

describe("withinSource", () => {
  it("covers the source and everything under it", () => {
    assert.equal(withinSource(model, 10, 10), true);
    assert.equal(withinSource(model, 10, 13), true);
    assert.equal(withinSource(model, 10, 20), false);
    assert.equal(withinSource(model, 12, 10), false);
  });
});

describe("resolveDrop: root zones", () => {
  it("top zone goes to the front of the root list", () => {
    assert.deepEqual(resolveDrop(model, { sourceId: 13, hit: { kind: "zone", zone: "top" } }), {
      kind: "zone",
      zone: "top",
      plan: { parentId: 99, position: 0, reorder: true },
    });
  });

  it("bottom zone appends to the root list, for a root source too", () => {
    assert.deepEqual(resolveDrop(model, { sourceId: 10, hit: { kind: "zone", zone: "bottom" } }), {
      kind: "zone",
      zone: "bottom",
      plan: { parentId: 99, position: null, reorder: true },
    });
  });
});

describe("resolveDrop: tail zone", () => {
  it("appends as the branch's last child", () => {
    assert.deepEqual(resolveDrop(model, { sourceId: 20, hit: { kind: "tail", branchId: 10 } }), {
      kind: "tail",
      branchId: 10,
      plan: { parentId: 10, position: 2, reorder: true },
    });
  });

  it("counts the source out when it is already in the branch", () => {
    assert.deepEqual(resolveDrop(model, { sourceId: 11, hit: { kind: "tail", branchId: 10 } }), {
      kind: "tail",
      branchId: 10,
      plan: { parentId: 10, position: 1, reorder: true },
    });
  });

  it("is forbidden on the source or a branch under it", () => {
    assert.deepEqual(resolveDrop(model, { sourceId: 10, hit: { kind: "tail", branchId: 10 } }), {
      kind: "forbidden",
      anchorId: 10,
    });
    assert.deepEqual(resolveDrop(model, { sourceId: 10, hit: { kind: "tail", branchId: 12 } }), {
      kind: "forbidden",
      anchorId: 12,
    });
  });
});

describe("resolveDrop: anchors that are not targets", () => {
  it("nothing under the pointer", () => {
    assert.deepEqual(resolveDrop(model, { sourceId: 10, hit: { kind: "none" } }), { kind: "none" });
  });

  it("the source itself", () => {
    assert.deepEqual(
      resolveDrop(model, { sourceId: 10, hit: { kind: "row", anchorId: 10, band: "above" } }),
      { kind: "none" },
    );
  });

  it("a descendant of the source", () => {
    assert.deepEqual(
      resolveDrop(model, { sourceId: 10, hit: { kind: "row", anchorId: 13, band: "center" } }),
      { kind: "none" },
    );
  });

  it("a row the model does not know", () => {
    assert.deepEqual(
      resolveDrop(model, { sourceId: 10, hit: { kind: "row", anchorId: 404, band: "below" } }),
      { kind: "none" },
    );
    assert.deepEqual(
      resolveDrop(model, { sourceId: 404, hit: { kind: "row", anchorId: 10, band: "below" } }),
      { kind: "none" },
    );
  });
});

describe("resolveDrop: center band", () => {
  it("reparents as the anchor's last child without a reorder pin", () => {
    assert.deepEqual(
      resolveDrop(model, { sourceId: 20, hit: { kind: "row", anchorId: 12, band: "center" } }),
      {
        kind: "reparent",
        anchorId: 12,
        plan: { parentId: 12, position: null, reorder: false },
      },
    );
  });

  it("is forbidden on the source's own parent, whose edges still work", () => {
    assert.deepEqual(
      resolveDrop(model, { sourceId: 11, hit: { kind: "row", anchorId: 10, band: "center" } }),
      { kind: "forbidden", anchorId: 10 },
    );
    assert.deepEqual(
      resolveDrop(model, { sourceId: 11, hit: { kind: "row", anchorId: 10, band: "above" } }),
      {
        kind: "placeholder",
        anchorId: 10,
        band: "above",
        plan: { parentId: 99, position: 0, reorder: true, anchor: { id: 10, side: "before" } },
      },
    );
    assert.deepEqual(
      resolveDrop(model, { sourceId: 11, hit: { kind: "row", anchorId: 10, band: "below" } }),
      {
        kind: "placeholder",
        anchorId: 10,
        band: "below",
        plan: { parentId: 99, position: 1, reorder: true, anchor: { id: 10, side: "after" } },
      },
    );
  });
});

describe("resolveDrop: edge bands", () => {
  it("reorders next to the anchor under the anchor's parent", () => {
    assert.deepEqual(
      resolveDrop(model, { sourceId: 20, hit: { kind: "row", anchorId: 13, band: "above" } }),
      {
        kind: "placeholder",
        anchorId: 13,
        band: "above",
        plan: { parentId: 12, position: 0, reorder: true, anchor: { id: 13, side: "before" } },
      },
    );
  });

  it("adjusts for a source earlier in the same list", () => {
    assert.deepEqual(
      resolveDrop(model, { sourceId: 10, hit: { kind: "row", anchorId: 30, band: "above" } }),
      {
        kind: "placeholder",
        anchorId: 30,
        band: "above",
        plan: { parentId: 99, position: 1, reorder: true, anchor: { id: 30, side: "before" } },
      },
    );
    assert.deepEqual(
      resolveDrop(model, { sourceId: 10, hit: { kind: "row", anchorId: 30, band: "below" } }),
      {
        kind: "placeholder",
        anchorId: 30,
        band: "below",
        plan: { parentId: 99, position: 2, reorder: true, anchor: { id: 30, side: "after" } },
      },
    );
  });

  it("does not adjust for a source later in the same list", () => {
    assert.deepEqual(
      resolveDrop(model, { sourceId: 30, hit: { kind: "row", anchorId: 10, band: "above" } }),
      {
        kind: "placeholder",
        anchorId: 10,
        band: "above",
        plan: { parentId: 99, position: 0, reorder: true, anchor: { id: 10, side: "before" } },
      },
    );
    assert.deepEqual(
      resolveDrop(model, { sourceId: 30, hit: { kind: "row", anchorId: 10, band: "below" } }),
      {
        kind: "placeholder",
        anchorId: 10,
        band: "below",
        plan: { parentId: 99, position: 1, reorder: true, anchor: { id: 10, side: "after" } },
      },
    );
  });
});
