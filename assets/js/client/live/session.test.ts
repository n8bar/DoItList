import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { buildTree } from "../tree/gen.ts";
import type { TreeModel } from "../tree/model.ts";
import { addTask, updateFields } from "../tree/ops.ts";
import type { Flight } from "../tree/optimistic.ts";
import { envelope, record } from "./fake_envelope.ts";
import type { SessionState } from "./session.ts";
import {
  BUFFER_LIMIT,
  acknowledge,
  begin,
  emptySession,
  gapOpen,
  heard,
  install,
  installCached,
  patchHeader,
  receive,
  reject,
  seqOf,
  shown,
} from "./session.ts";

// root 1 ─ 10
//        └ 11
const snapshot = (seq: number, indexStyle = "numerical") =>
  buildTree([{ id: 10 }, { id: 11 }], { id: 12, seq, indexStyle });

/** A session with the snapshot at `seq` installed. */
const at = (seq: number): SessionState => install(emptySession, snapshot(seq)).state;

const retitle = (seq: number, id: number, title: string) =>
  envelope(seq, { upserts: [record(id, 1, id - 10, { title, version: 2 })] });

const rootIds = (model: TreeModel | null) => model?.childIds[1] ?? [];

/** An add's prediction: a stand-in row at the end of the top level. */
const addFlight = (key: string, tempId = -1): Flight => ({
  key,
  predict: (base) => {
    const result = addTask(base, { tempId, parentId: 1, position: 2, title: "New" });
    return "model" in result ? result.model : base;
  },
  tempId,
});

const editFlight = (key: string, id: number, title: string): Flight => ({
  key,
  predict: (base) => updateFields(base, id, { title }).model,
  tempId: null,
});

/** The reply an add gets: the new record, at the slot it asked for. */
const addReply = { upserts: [{ id: 13, parent_id: 1, position: 2, title: "New", version: 1 }], removed: [] };

describe("consecutive delivery (1.4.3)", () => {
  it("applies the next envelope once and advances the sequence", () => {
    const first = receive(at(3), retitle(4, 11, "Doors"));
    assert.equal(first.state.canonical?.tasks[11]?.title, "Doors");
    assert.equal(seqOf(first.state), 4);
    assert.equal(first.applied.length, 1);
    assert.equal(gapOpen(first.state), false);

    // The same envelope again is a repeat: nothing moves, not even identity.
    const again = receive(first.state, retitle(4, 11, "Doors"));
    assert.equal(again.state, first.state);
    assert.equal(again.applied.length, 0);
  });

  it("a roll-up envelope (no origin) is an ordinary consecutive delta, under a pending write", () => {
    const pending = begin(at(3), editFlight("k", 11, "Mine"));
    const rolled = receive(
      pending,
      envelope(4, { upserts: [record(10, 1, 0, { progress: 50, manual_progress: 50, version: 2 })] }),
    );
    assert.equal(rolled.state.canonical?.tasks[10]?.progress, 50);
    assert.equal(rolled.state.flights.length, 1, "the write is still pending");
    const view = shown(rolled.state);
    assert.equal(view?.tasks[10]?.progress, 50, "truth shows");
    assert.equal(view?.tasks[11]?.title, "Mine", "the prediction is re-run over it");
    assert.equal(rolled.state.canonical?.tasks[11]?.title, "Task 11", "canonical never holds a guess");
  });

  it("a header patch relabels from the new index style and adopts the new calc", () => {
    const restyled = receive(
      at(3),
      envelope(4, {
        initiative: {
          version: 2,
          name: "Renamed",
          subtitle: "",
          progress: 0,
          unit_count: 2,
          progress_calc: "single_level",
          index_style: "roman",
        },
      }),
    );
    const model = restyled.state.canonical;
    assert.equal(model?.header.name, "Renamed");
    assert.equal(model?.indexStyle, "roman");
    assert.equal(model?.progressCalc, "single_level");
    assert.equal(model?.tasks[10]?.index, "I");
    assert.equal(model?.tasks[11]?.index, "II");
  });
});

describe("old delivery (1.4.2)", () => {
  it("drops an envelope at or below the sequence", () => {
    const state = at(3);
    for (const seq of [1, 2, 3]) {
      const outcome = receive(state, retitle(seq, 11, "Stale"));
      assert.equal(outcome.state, state, `seq ${seq}`);
      assert.equal(outcome.applied.length, 0);
    }
  });
});

describe("gaps (1.4.4)", () => {
  it("holds an envelope that skips ahead, and applies it once the one before lands", () => {
    const ahead = receive(at(3), retitle(5, 11, "Five"));
    assert.equal(seqOf(ahead.state), 3);
    assert.equal(ahead.state.canonical?.tasks[11]?.title, "Task 11");
    assert.equal(gapOpen(ahead.state), true);
    assert.equal(ahead.overflow, false);

    const filled = receive(ahead.state, retitle(4, 10, "Four"));
    assert.equal(seqOf(filled.state), 5);
    assert.deepEqual(
      filled.applied.map((e) => e.seq),
      [4, 5],
    );
    assert.equal(filled.state.canonical?.tasks[10]?.title, "Four");
    assert.equal(filled.state.canonical?.tasks[11]?.title, "Five");
    assert.equal(gapOpen(filled.state), false);
    assert.equal(filled.state.buffered.size, 0);
  });

  it("a snapshot older than a held envelope installs, and the held one follows", () => {
    const held = receive(at(3), retitle(6, 11, "Six"));
    const snap = snapshot(5);
    (snap.tasks[0] as { title: string }).title = "From the read";
    const read = install(held.state, snap);
    assert.equal(read.installed, true);
    assert.equal(seqOf(read.state), 6);
    assert.equal(read.state.canonical?.tasks[10]?.title, "From the read");
    assert.equal(read.state.canonical?.tasks[11]?.title, "Six");
    assert.equal(gapOpen(read.state), false);
  });

  it("a snapshot newer than the held envelopes makes them moot", () => {
    let state = receive(at(3), retitle(5, 11, "Five")).state;
    state = receive(state, retitle(6, 11, "Six")).state;
    const read = install(state, snapshot(7));
    assert.equal(seqOf(read.state), 7);
    assert.equal(read.applied.length, 0);
    assert.equal(read.state.buffered.size, 0);
    assert.equal(read.state.canonical?.tasks[11]?.title, "Task 11", "the read is truth");
  });

  it("a snapshot that still leaves a gap keeps the gap open", () => {
    let state = receive(at(3), retitle(6, 11, "Six")).state;
    state = receive(state, retitle(7, 11, "Seven")).state;
    const read = install(state, snapshot(4));
    assert.equal(seqOf(read.state), 4);
    assert.equal(read.state.buffered.size, 2);
    assert.equal(gapOpen(read.state), true);
  });

  it("never installs a snapshot older than what it holds", () => {
    const state = at(5);
    const read = install(state, snapshot(4));
    assert.equal(read.installed, false);
    assert.equal(read.state, state);
    // Equal is fine: a Try again re-read lands.
    assert.equal(install(state, snapshot(5)).installed, true);
  });

  it("past the buffer limit it asks for a re-read at once and keeps the newest", () => {
    let outcome = receive(at(3), retitle(5, 11, "x"));
    for (let seq = 6; seq <= 4 + BUFFER_LIMIT; seq += 1) {
      outcome = receive(outcome.state, retitle(seq, 11, "x"));
      assert.equal(outcome.overflow, false, `seq ${seq}`);
    }
    assert.equal(outcome.state.buffered.size, BUFFER_LIMIT);
    const over = receive(outcome.state, retitle(5 + BUFFER_LIMIT, 11, "x"));
    assert.equal(over.overflow, true);
    assert.equal(over.state.buffered.size, BUFFER_LIMIT);
    assert.equal(over.state.buffered.has(5), false, "the oldest went");
    assert.equal(over.state.buffered.has(5 + BUFFER_LIMIT), true);
  });
});

describe("before the snapshot", () => {
  it("holds what arrives before canonical exists, and never asks for a re-read", () => {
    let outcome = receive(emptySession, retitle(4, 11, "Four"));
    outcome = receive(outcome.state, retitle(5, 11, "Five"));
    assert.equal(outcome.state.canonical, null);
    assert.equal(gapOpen(outcome.state), false);
    assert.equal(outcome.overflow, false);
    assert.equal(shown(outcome.state), null);

    // The read lands at 4: 4 is moot, 5 follows.
    const read = install(outcome.state, snapshot(4));
    assert.equal(seqOf(read.state), 5);
    assert.deepEqual(
      read.applied.map((e) => e.seq),
      [5],
    );
    assert.equal(read.state.canonical?.tasks[11]?.title, "Five");
  });

  it("a flood before the snapshot is bounded without asking for a re-read", () => {
    let outcome = receive(emptySession, retitle(1, 11, "x"));
    for (let seq = 2; seq <= BUFFER_LIMIT + 5; seq += 1) {
      outcome = receive(outcome.state, retitle(seq, 11, "x"));
    }
    assert.equal(outcome.overflow, false);
    assert.equal(outcome.state.buffered.size, BUFFER_LIMIT);
  });
});

describe("own writes (1.4.1)", () => {
  const broadcast = (key: string) =>
    envelope(4, { originKey: key, upserts: [record(13, 1, 2, { title: "New", index: "3" })] });

  it("reply first: the reply lands and drops the prediction; the broadcast then lands its full record", () => {
    const pending = begin(at(3), addFlight("k"));
    assert.deepEqual(rootIds(shown(pending)), [10, 11, -1], "the stand-in shows at once");

    const answered = acknowledge(pending, "k", addReply, 4);
    assert.equal(answered.createdId, 13);
    assert.equal(answered.flight?.tempId, -1);
    assert.equal(answered.state.flights.length, 0);
    assert.deepEqual(rootIds(shown(answered.state)), [10, 11, 13], "one row, the server's");
    assert.equal(seqOf(answered.state), 3, "the reply does not stand in for the envelope");
    assert.equal(gapOpen(answered.state), true, "the server is known to be at 4");

    const settled = receive(answered.state, broadcast("k"));
    assert.equal(settled.settled.length, 0, "nothing left to settle");
    assert.equal(seqOf(settled.state), 4);
    assert.equal(gapOpen(settled.state), false);
    assert.deepEqual(rootIds(shown(settled.state)), [10, 11, 13]);
    assert.equal(settled.state.canonical?.tasks[13]?.index, "3", "the full record is in");
  });

  it("broadcast first: the envelope settles the write; the reply then has nothing to do", () => {
    const pending = begin(at(3), addFlight("k"));
    const settled = receive(pending, broadcast("k"));
    assert.deepEqual(settled.settled.map((s) => [s.flight.key, s.createdId]), [["k", 13]]);
    assert.equal(settled.state.flights.length, 0);
    assert.deepEqual(rootIds(shown(settled.state)), [10, 11, 13], "the stand-in is gone, the row is not doubled");
    assert.equal(seqOf(settled.state), 4);

    const answered = acknowledge(settled.state, "k", addReply, 4);
    assert.equal(answered.createdId, null);
    assert.equal(answered.flight, null);
    assert.equal(answered.state.canonical, settled.state.canonical, "canonical is untouched");
    assert.equal(answered.state.acked.has("k"), false, "the key is forgotten");
  });

  it("either order ends in the same tree", () => {
    const pending = begin(at(3), addFlight("k"));
    const replyFirst = receive(acknowledge(pending, "k", addReply, 4).state, broadcast("k")).state;
    const broadcastFirst = acknowledge(receive(pending, broadcast("k")).state, "k", addReply, 4).state;
    assert.deepEqual(replyFirst.canonical?.childIds, broadcastFirst.canonical?.childIds);
    assert.deepEqual(replyFirst.canonical?.tasks, broadcastFirst.canonical?.tasks);
    assert.equal(seqOf(replyFirst), seqOf(broadcastFirst));
  });

  it("a reply whose sequence is beyond the next says envelopes are missing", () => {
    const answered = acknowledge(begin(at(3), addFlight("k")), "k", addReply, 6);
    assert.equal(gapOpen(answered.state), true);
    assert.equal(answered.state.expected, 6);
  });

  it("a reply with no sequence (an older server) just lands", () => {
    const answered = acknowledge(begin(at(3), addFlight("k")), "k", addReply);
    assert.equal(answered.createdId, 13);
    assert.equal(gapOpen(answered.state), false);
  });

  it("someone else's envelope under a pending write keeps the prediction on top", () => {
    const pending = begin(at(3), editFlight("k", 11, "Mine"));
    const theirs = receive(pending, retitle(4, 10, "Theirs"));
    const view = shown(theirs.state);
    assert.equal(view?.tasks[10]?.title, "Theirs");
    assert.equal(view?.tasks[11]?.title, "Mine");
    assert.equal(theirs.settled.length, 0);
  });

  it("a rejection drops the prediction and nothing else", () => {
    const pending = begin(at(3), editFlight("k", 11, "Mine"));
    const dropped = reject(pending, "k");
    assert.equal(dropped.flights.length, 0);
    assert.equal(shown(dropped)?.tasks[11]?.title, "Task 11");
    assert.equal(dropped.canonical, pending.canonical);
  });

  it("a header patch goes on canonical, under the predictions", () => {
    const pending = begin(at(3), editFlight("k", 11, "Mine"));
    const renamed = patchHeader(pending, (header) => ({ ...header, name: "Renamed" }));
    assert.equal(renamed.canonical?.header.name, "Renamed");
    assert.equal(shown(renamed)?.header.name, "Renamed");
    assert.equal(shown(renamed)?.tasks[11]?.title, "Mine");
    assert.equal(patchHeader(emptySession, (h) => h), emptySession);
  });
});

describe("subscribed before the snapshot (m04.03 3.1)", () => {
  it("an envelope held before the read applies after it when it is newer", () => {
    const held = receive(emptySession, retitle(4, 11, "Four"));
    const read = install(held.state, snapshot(3));
    assert.equal(read.installed, true);
    assert.equal(read.applied.length, 1);
    assert.equal(seqOf(read.state), 4);
    assert.equal(read.state.canonical?.tasks[11]?.title, "Four");
    assert.equal(read.state.synced, true);
  });

  it("an envelope the snapshot already covers is dropped", () => {
    const held = receive(emptySession, retitle(3, 11, "Old"));
    const read = install(held.state, snapshot(3));
    assert.equal(read.applied.length, 0);
    assert.equal(read.state.buffered.size, 0);
    assert.equal(read.state.canonical?.tasks[11]?.title, "Task 11", "the read is truth");
  });

  it("a snapshot newer than everything held makes all of it moot", () => {
    let state = receive(emptySession, retitle(2, 11, "Two")).state;
    state = receive(state, retitle(3, 11, "Three")).state;
    const read = install(state, snapshot(9));
    assert.equal(read.applied.length, 0);
    assert.equal(seqOf(read.state), 9);
    assert.equal(read.state.buffered.size, 0);
  });

  it("a gap among the held ones stays a gap for the caller to re-read", () => {
    let state = receive(emptySession, retitle(4, 11, "Four")).state;
    state = receive(state, retitle(6, 11, "Six")).state;
    const read = install(state, snapshot(3));
    assert.equal(seqOf(read.state), 4, "the consecutive one followed");
    assert.equal(read.state.buffered.size, 1);
    assert.equal(gapOpen(read.state), true);
  });
});

describe("what a join reply says (m04.03 3.3)", () => {
  it("a sequence past canonical opens the gap without applying anything", () => {
    const state = heard(at(3), 5);
    assert.equal(seqOf(state), 3);
    assert.equal(gapOpen(state), true);
  });

  it("a sequence at or below canonical changes nothing", () => {
    const state = at(3);
    assert.equal(heard(state, 3), state);
    assert.equal(heard(state, 1), state);
  });

  it("the device's copy is not a server snapshot", () => {
    assert.equal(emptySession.synced, false);
    assert.equal(installCached(emptySession, at(2).canonical as TreeModel).state.synced, false);
    assert.equal(install(emptySession, snapshot(2)).state.synced, true);
  });
});

describe("the device's copy (m04.03 2.2)", () => {
  it("fills an empty session, and the server's read installs forward over it", () => {
    const cached = { ...install(emptySession, snapshot(3)).state.canonical!, seq: 3 };
    const primed = installCached(emptySession, cached);
    assert.equal(primed.installed, true);
    assert.equal(seqOf(primed.state), 3);
    assert.deepEqual(shown(primed.state), cached);

    const read = install(primed.state, snapshot(5));
    assert.equal(read.installed, true);
    assert.equal(seqOf(read.state), 5);
  });

  it("is refused once the server has said anything, and an older read is refused over it", () => {
    const cached = install(emptySession, snapshot(3)).state.canonical!;
    assert.equal(installCached(at(4), cached).installed, false);
    assert.equal(installCached(at(2), cached).installed, false, "the session's own truth is never overwritten");

    const primed = installCached(emptySession, { ...cached, seq: 6 }).state;
    assert.equal(install(primed, snapshot(5)).installed, false, "a read older than the copy is refused");
    assert.equal(seqOf(primed), 6);
  });

  it("drains envelopes held while the copy was being read, and drops those it already covers", () => {
    let state = receive(emptySession, retitle(4, 11, "Four")).state;
    state = receive(state, retitle(2, 11, "Two")).state;
    const cached = install(emptySession, snapshot(3)).state.canonical!;

    const primed = installCached(state, cached);
    assert.equal(primed.installed, true);
    assert.equal(seqOf(primed.state), 4);
    assert.equal(primed.state.canonical?.tasks[11]?.title, "Four");
    assert.equal(primed.state.buffered.size, 0);
  });
});
