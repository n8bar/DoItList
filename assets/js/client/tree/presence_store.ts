// Presence as each row reads it (m04.02 item 7.17).
//
// The channel's presence lands as one new state object per change — and a
// change includes this window's own `select` coming back to it. Held in the
// tree context as a value, every echo of my own selection gave the context a
// new identity and re-rendered every row for a change no row could see. So,
// like the collapse set (7.9.1) and the selection (2.2.3), presence is a store
// of its own: each row subscribes for its badges and its assignee's dot, and a
// change that leaves them alone leaves the row alone.
//
// The one rule that makes the subscription cheap: a row's badges are the SAME
// array back until they change. `useSyncExternalStore` compares snapshots by
// identity, so a fresh array per read would re-render every row on every
// notify — the very thing this store exists to stop.

import type { Selection } from "../live/presence_model.ts";
import type { RowPresence } from "./row_model.ts";
import { noPresence } from "./row_model.ts";

/** What a row (or the pane) reads. Every method is stable for the store's life. */
export interface PresenceReader {
  subscribe(listener: () => void): () => void;
  /** Other members with `taskId` selected — one badge each, in arrival order. */
  badges(taskId: number): readonly Selection[];
  /** Whether `userId` is on the channel. Nobody is `null`. */
  online(userId: number | null): boolean;
  /** Everyone on the channel, self included. The same set back until it changes. */
  onlineIds(): ReadonlySet<number>;
}

export interface PresenceStore extends PresenceReader {
  /**
   * Files a new view. Rows whose badges are unchanged keep their array, the
   * online set is kept when its members are, and nothing is notified when
   * nothing a reader could see has changed.
   */
  set(next: RowPresence): void;
}

const NO_BADGES: readonly Selection[] = [];

const sameSelection = (a: Selection, b: Selection): boolean =>
  a.user_id === b.user_id &&
  a.task_id === b.task_id &&
  a.name === b.name &&
  a.initials === b.initials &&
  a.bg === b.bg &&
  a.fg === b.fg;

const sameBadges = (a: readonly Selection[], b: readonly Selection[]): boolean =>
  a.length === b.length && a.every((selection, i) => sameSelection(selection, b[i] as Selection));

const sameIds = (a: ReadonlySet<number>, b: ReadonlySet<number>): boolean =>
  a.size === b.size && [...a].every((id) => b.has(id));

/** Selections grouped by task, in arrival order. */
function byTask(selections: readonly Selection[]): Map<number, readonly Selection[]> {
  const out = new Map<number, Selection[]>();
  for (const selection of selections) {
    const held = out.get(selection.task_id);
    if (held === undefined) out.set(selection.task_id, [selection]);
    else held.push(selection);
  }
  return out;
}

export function createPresenceStore(initial: RowPresence = noPresence): PresenceStore {
  let badges = byTask(initial.selections);
  let online: ReadonlySet<number> = initial.online;
  const listeners = new Set<() => void>();

  return {
    subscribe(listener) {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    badges: (taskId) => badges.get(taskId) ?? NO_BADGES,
    online: (userId) => userId !== null && online.has(userId),
    onlineIds: () => online,

    set(next) {
      let changed = false;

      const incoming = byTask(next.selections);
      const merged = new Map<number, readonly Selection[]>();
      for (const [taskId, list] of incoming) {
        const held = badges.get(taskId);
        if (held !== undefined && sameBadges(held, list)) merged.set(taskId, held);
        else {
          merged.set(taskId, list);
          changed = true;
        }
      }
      if (merged.size !== badges.size) changed = true;
      badges = merged;

      if (!sameIds(online, next.online)) {
        online = next.online;
        changed = true;
      }

      if (!changed) return;
      for (const listener of [...listeners]) listener();
    },
  };
}

/** Nobody here — the reader a tree gets when no channel is feeding one. */
export const nobodyPresent: PresenceReader = createPresenceStore();
