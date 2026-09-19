import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

import type { Member } from "../api/types.ts";
import { buildTree } from "./gen.ts";
import { fromSnapshot } from "./model.ts";
import {
  CO_AVATAR_CAP,
  assigneeView,
  avatarStyle,
  badgeIcon,
  badgeIconClass,
  badgeTitle,
  botanicalColor,
  botanicalKind,
  branchUnitTitle,
  chipOnline,
  memberIndex,
  noPresence,
  progressValue,
  refLabelOf,
  refParts,
  rowBadges,
} from "./row_model.ts";
import type { RowPresence } from "./row_model.ts";
import type { Selection } from "../live/presence_model.ts";

const model = () =>
  fromSnapshot(
    buildTree(
      [
        {
          id: 10,
          title: "Cabinets",
          progress: 75,
          children: [
            { id: 11, manual_progress: 50 },
            { id: 12, status: "done" },
          ],
        },
        { id: 20, title: "Worktop", manual_progress: 30 },
      ],
      { rootTaskId: 99 },
    ),
  );

const member = (user_id: number, username: string, name: string | null = null): Member => ({
  user_id,
  role: "editor",
  name,
  username,
});

describe("the row's type glyph", () => {
  it("is a tree at the top level, a branch with children, a leaf without", () => {
    const m = model();
    assert.equal(botanicalKind(m, 10, 0), "tree");
    assert.equal(botanicalKind(m, 10, 1), "branch");
    assert.equal(botanicalKind(m, 11, 1), "leaf");
  });

  it("colours branches amber and everything else emerald", () => {
    assert.equal(botanicalColor("branch"), "text-amber-700 dark:text-amber-600");
    assert.equal(botanicalColor("leaf"), "text-emerald-600 dark:text-emerald-400");
    assert.equal(botanicalColor("tree"), "text-emerald-600 dark:text-emerald-400");
  });
});

describe("the number a row shows (progress_value/1)", () => {
  it("shows a branch's roll-up, a done task's 100, and a leaf's own input", () => {
    const m = model();
    assert.equal(progressValue(m, 10), 75);
    assert.equal(progressValue(m, 12), 100);
    assert.equal(progressValue(m, 11), 50);
    assert.equal(progressValue(m, 20), 30);
  });

  it("shows nothing rather than throwing for a task the model lost", () => {
    assert.equal(progressValue(model(), 404), 0);
  });
});

describe("the count badge", () => {
  it("names the roll-up mode in its glyph, its colour and its words", () => {
    assert.equal(badgeIcon("leaf_average"), "leaf");
    assert.equal(badgeIcon("single_level"), "branch");
    assert.equal(badgeIconClass("leaf_average"), "w-3 h-3 flex-none");
    assert.match(badgeIconClass("single_level"), /text-amber-700/);
    assert.equal(branchUnitTitle("leaf_average"), "Leaves in this branch");
    assert.equal(branchUnitTitle("single_level"), "Direct children — each counts equally");
  });
});

describe("the assignee chip", () => {
  const members = memberIndex([member(5, "ada", "Ada Lovelace"), member(6, "bo"), member(7, "cy")]);

  it("reads unassigned as the default, unset state", () => {
    const m = model();
    const view = assigneeView(m.tasks[11]!, members);
    assert.equal(view.user, null);
    assert.equal(view.set, false);
    assert.equal(view.title, "Unassigned");
  });

  it("names the assignee by username", () => {
    const m = fromSnapshot(buildTree([{ id: 10, assignee_id: 5 }], { rootTaskId: 99 }));
    const view = assigneeView(m.tasks[10]!, members);
    assert.equal(view.user?.username, "ada");
    assert.equal(view.set, true);
    assert.equal(view.exMember, false);
    assert.equal(view.title, "Assignee: @ada");
  });

  it("says so when the assignee is no longer a member", () => {
    const m = fromSnapshot(buildTree([{ id: 10, assignee_id: 404 }], { rootTaskId: 99 }));
    const view = assigneeView(m.tasks[10]!, members);
    assert.equal(view.user, null);
    assert.equal(view.exMember, true);
    assert.equal(view.title, "Assignee: (no longer a member)");
  });

  it("draws the co-assignees it knows and counts the ones it doesn't", () => {
    const m = fromSnapshot(
      buildTree([{ id: 10, assignee_id: 5, co_assignee_ids: [6, 7, 404] }], { rootTaskId: 99 }),
    );
    const view = assigneeView(m.tasks[10]!, members);

    assert.deepEqual(
      view.coUsers.map((u) => u.username),
      ["bo", "cy"],
    );
    assert.equal(view.coCount, 3);
    assert.equal(view.coOverflow, 1);
  });

  it("caps the avatars at the server's cap and counts the overflow", () => {
    const ids = Array.from({ length: CO_AVATAR_CAP + 3 }, (_, i) => 100 + i);
    const many = memberIndex(ids.map((id) => member(id, `u${id}`)));
    const m = fromSnapshot(buildTree([{ id: 10, co_assignee_ids: ids }], { rootTaskId: 99 }));
    const view = assigneeView(m.tasks[10]!, many);

    assert.equal(view.coUsers.length, CO_AVATAR_CAP);
    assert.equal(view.coOverflow, 3);
    assert.equal(view.set, true);
  });

  it("caps at the same number DoIt.Tasks does", () => {
    const source = readFileSync(new URL("../../../../lib/doit/tasks.ex", import.meta.url), "utf8");
    assert.match(source, new RegExp(`@co_avatar_cap ${CO_AVATAR_CAP}\\b`));
  });

  it("derives the avatar's colours the way the server derives them", () => {
    // CoreComponents.avatar_bg/1 for id 1: rem(137,360)=137deg, #0284c7, #9333ea.
    assert.deepEqual(avatarStyle({ id: 1, name: null, username: "x" }), {
      backgroundImage: "linear-gradient(137deg, #0284c7, #9333ea)",
      color: "#bae6fd",
    });
  });
});

describe("reference chips", () => {
  const m = () =>
    fromSnapshot(
      buildTree([{ id: 10, children: [{ id: 11 }, { id: 12 }] }, { id: 20 }], { rootTaskId: 99 }),
    );

  it("resolves a reference to the target's live label", () => {
    assert.deepEqual(refParts("see %<12> first", m()), [
      { kind: "text", text: "see " },
      { kind: "link", id: 12, label: "1.2" },
      { kind: "text", text: " first" },
    ]);
  });

  it("marks a reference this tree does not hold as dead, never as raw text", () => {
    assert.deepEqual(refParts("see %<404>", m()), [
      { kind: "text", text: "see " },
      { kind: "dead", id: 404 },
    ]);
  });

  it("falls back to the arrow glyph when the Initiative is not numbered", () => {
    const unnumbered = fromSnapshot(
      buildTree([{ id: 10 }], { rootTaskId: 99, indexStyle: "none" }),
    );
    assert.equal(refLabelOf(unnumbered, 10), null);
    assert.deepEqual(refParts("%<10>", unnumbered), [{ kind: "link", id: 10, label: "↗" }]);
  });

  it("resolves escapes and leaves a bare percent alone, as refs.js does", () => {
    assert.deepEqual(refParts("100\\% of %<20> and a bare %", m()), [
      { kind: "text", text: "100% of " },
      { kind: "link", id: 20, label: "2" },
      { kind: "text", text: " and a bare %" },
    ]);
  });

  it("uses the one parser, not a second copy", () => {
    const source = readFileSync(new URL("./row_model.ts", import.meta.url), "utf8");
    assert.match(source, /import \{ segments \} from "\.\.\/\.\.\/refs\.js";/);
  });
});

describe("presence on a row (item 3.4.2)", () => {
  const selection = (user_id: number, task_id: number): Selection => ({
    user_id,
    task_id,
    field: null,
    name: `User ${user_id}`,
    initials: `U${user_id}`,
    bg: `bg-${user_id}`,
    fg: `fg-${user_id}`,
  });
  const presence: RowPresence = {
    selections: [selection(2, 10), selection(3, 11), selection(4, 10)],
    online: new Set([1, 2]),
  };

  it("wears one badge per other member with this row selected, in arrival order", () => {
    assert.deepEqual(
      rowBadges(presence, 10).map((s) => s.user_id),
      [2, 4],
    );
    assert.deepEqual(rowBadges(presence, 11).map((s) => s.user_id), [3]);
    assert.deepEqual(rowBadges(presence, 12), []);
    assert.deepEqual(rowBadges(noPresence, 10), []);
  });

  it("names who has it selected", () => {
    assert.equal(badgeTitle(selection(2, 10)), "User 2 has this task selected");
  });

  it("lights the assignee chip only when that user is on the channel", () => {
    assert.equal(chipOnline(presence, 1), true);
    assert.equal(chipOnline(presence, 2), true);
    assert.equal(chipOnline(presence, 3), false);
    assert.equal(chipOnline(presence, null), false);
    assert.equal(chipOnline(noPresence, 1), false);
  });
});
