import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { deltaFrom, parseDelta } from "./envelope.ts";
import { envelope, record, wire } from "./fake_envelope.ts";

const patch = {
  version: 3,
  name: "Kitchen",
  subtitle: "",
  progress: 40,
  unit_count: 5,
  progress_calc: "leaf_average" as const,
  index_style: "roman",
};

describe("parseDelta (item 1.4)", () => {
  it("accepts the envelope the server sends, with the record fill-ins a snapshot gets", () => {
    const sent = wire(
      envelope(4, {
        originKey: "k-1",
        actor: { id: 7, name: "Ann", username: "ann" },
        upserts: [record(21, 1, 0)],
        removed: [22],
        initiative: patch,
        membersChanged: true,
      }),
    );
    // A record that predates the sort pair and the editor pair.
    const bare = { ...(sent["upserts"] as object[])[0] } as Record<string, unknown>;
    delete bare["sort_mode"];
    delete bare["sort_reverse"];
    delete bare["updated_by"];
    delete bare["updated_at"];
    sent["upserts"] = [bare];

    const parsed = parseDelta(12, sent);
    assert.ok(parsed);
    assert.equal(parsed.seq, 4);
    assert.equal(parsed.originKey, "k-1");
    assert.deepEqual(parsed.actor, { id: 7, name: "Ann", username: "ann" });
    assert.deepEqual(parsed.removed, [22]);
    assert.deepEqual(parsed.initiative, patch);
    assert.equal(parsed.membersChanged, true);
    assert.equal(parsed.upserts[0]?.sort_mode, null);
    assert.equal(parsed.upserts[0]?.sort_reverse, false);
    assert.equal(parsed.upserts[0]?.updated_by, null);
    assert.equal(parsed.upserts[0]?.updated_at, null);
  });

  it("reads a missing origin key and actor as none", () => {
    const sent = wire(envelope(1));
    delete sent["origin_key"];
    sent["actor"] = null;
    const parsed = parseDelta(12, sent);
    assert.ok(parsed);
    assert.equal(parsed.originKey, null);
    assert.equal(parsed.actor, null);
    assert.equal(parsed.initiative, null);
  });

  it("drops what it cannot apply whole", () => {
    const good = () => wire(envelope(2, { upserts: [record(21, 1, 0)] }));
    const cases: Array<[string, unknown]> = [
      ["not a record", "nope"],
      ["another Initiative's", { ...good(), initiative_id: 13 }],
      ["no sequence", { ...good(), seq: undefined }],
      ["a zero sequence", { ...good(), seq: 0 }],
      ["a fractional sequence", { ...good(), seq: 2.5 }],
      ["an origin key that is not a string", { ...good(), origin_key: 9 }],
      ["upserts that are not a list", { ...good(), upserts: {} }],
      ["a record with no id", { ...good(), upserts: [{ ...record(21, 1, 0), id: "21" }] }],
      ["a record with no parent", { ...good(), upserts: [{ ...record(21, 1, 0), parent_id: null }] }],
      ["a record with no position", { ...good(), upserts: [{ ...record(21, 1, 0), position: "0" }] }],
      ["a record with no version", { ...good(), upserts: [{ ...record(21, 1, 0), version: undefined }] }],
      ["removed ids that are not numbers", { ...good(), removed: ["22"] }],
      ["a header patch missing its style", { ...good(), initiative: { ...patch, index_style: 1 } }],
      ["no members flag", { ...good(), members_changed: "yes" }],
    ];
    for (const [name, payload] of cases) {
      assert.equal(parseDelta(12, payload), null, name);
    }
    assert.ok(parseDelta(12, good()), "the good one parses");
  });
});

describe("deltaFrom", () => {
  it("maps the records and the header fields the model keeps", () => {
    const delta = deltaFrom(
      envelope(4, { upserts: [record(21, 1, 0)], removed: [22], initiative: patch }),
    );
    assert.equal(delta.upserts[0]?.id, 21);
    assert.deepEqual(delta.removed, [22]);
    assert.deepEqual(delta.initiative, {
      name: "Kitchen",
      subtitle: "",
      progress: 40,
      unit_count: 5,
      version: 3,
    });
  });

  it("carries no header when the envelope has none", () => {
    assert.equal("initiative" in deltaFrom(envelope(4)), false);
  });
});
