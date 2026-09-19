// What a cached Initiative is, and who writes it (m04.01 items 3.4, 3.6; m04.03 2.2).
//
// The whole canonical tree is cached — records, child order, header and the
// delivery sequence it is current to — never what is shown: a prediction is a
// guess, and a guess written to disk would come back as truth. On the next
// load the cached tree is installed and painted before the server answers,
// and the server's read installs forward over it (the session refuses an
// older one), so the page starts from the last thing the server confirmed.
//
// Every write is fire-and-forget on purpose. Caching is a courtesy to the next
// page load — a user's action must never wait on it (UX_GUARDRAILS §6). The
// cache is bounded (`bounds.ts`) and disposable: a record that does not read
// back as a tree is deleted and ignored, and the server is asked instead.

import type { TreeModel } from "../tree/model.ts";
import { validateModel } from "../tree/validate.ts";
import type { AccountStorage } from "./db.ts";

export const LAST_SNAPSHOT_KEY = "last_snapshot";

/** Which Initiative the newest snapshot covers. Mirrored into the recovery store. */
export interface SnapshotMeta {
  readonly initiativeId: number;
  /** The Initiative's `version` — what the header showed. */
  readonly version: number;
  /** The delivery sequence the cached tree is current to. */
  readonly seq: number;
  readonly savedAt: number;
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

const ROLES: ReadonlySet<string> = new Set(["owner", "editor", "viewer"]);
const CALCS: ReadonlySet<string> = new Set(["leaf_average", "single_level"]);

/** The payload as written: the model, whole, with nothing derived. */
export function treePayload(model: TreeModel): TreeModel {
  return {
    initiativeId: model.initiativeId,
    rootId: model.rootId,
    header: model.header,
    tasks: model.tasks,
    childIds: model.childIds,
    progressCalc: model.progressCalc,
    indexStyle: model.indexStyle,
    seq: model.seq,
  };
}

/**
 * A cached payload as a model, or `null` for anything that is not one. The
 * shape is checked field by field and the structure by the same rules an
 * operation's result must meet (`validateModel`): a tree that would not have
 * been accepted from the server is not accepted from the disk either.
 */
export function parseTreeModel(value: unknown): TreeModel | null {
  if (!isRecord(value)) return null;
  const { initiativeId, rootId, header, tasks, childIds, progressCalc, indexStyle, seq } = value;
  if (typeof initiativeId !== "number" || typeof rootId !== "number" || typeof seq !== "number") {
    return null;
  }
  if (typeof progressCalc !== "string" || !CALCS.has(progressCalc)) return null;
  if (typeof indexStyle !== "string") return null;
  if (!isRecord(header) || !isRecord(tasks) || !isRecord(childIds)) return null;
  if (
    header["id"] !== initiativeId ||
    typeof header["name"] !== "string" ||
    typeof header["role"] !== "string" ||
    !ROLES.has(header["role"]) ||
    typeof header["progress"] !== "number" ||
    typeof header["unit_count"] !== "number" ||
    typeof header["version"] !== "number"
  ) {
    return null;
  }
  for (const record of Object.values(tasks)) {
    if (!isRecord(record) || typeof record["id"] !== "number") return null;
    if (typeof record["parent_id"] !== "number" || typeof record["position"] !== "number") return null;
    if (typeof record["title"] !== "string" || typeof record["version"] !== "number") return null;
  }
  for (const order of Object.values(childIds)) {
    if (!Array.isArray(order) || order.some((id) => typeof id !== "number")) return null;
  }

  const model = value as unknown as TreeModel;
  return validateModel(model).ok ? model : null;
}

export function parseSnapshotMeta(value: unknown): SnapshotMeta | null {
  if (!isRecord(value)) return null;
  const { initiativeId, version, seq, savedAt } = value;
  if (
    typeof initiativeId !== "number" ||
    typeof version !== "number" ||
    typeof seq !== "number" ||
    typeof savedAt !== "number"
  ) {
    return null;
  }
  return { initiativeId, version, seq, savedAt };
}

export interface TreeCache {
  /** Caches a canonical tree. Never throws, never awaited. */
  cacheTree(model: TreeModel): void;
  /** The same write, awaitable — for callers that must know when it landed. */
  writeTree(model: TreeModel): Promise<boolean>;
  /**
   * The last tree saved on this device, or `null`. Never throws. A record
   * that does not read back as a tree is deleted on the way.
   */
  readTree(initiativeId: number): Promise<TreeModel | null>;
  /**
   * Throws away everything cached for one Initiative: the snapshot, and the
   * "newest snapshot" pointer if it named this one. Access loss is a purge
   * trigger, exactly like signing out (spec §12).
   */
  forgetTree(initiativeId: number): Promise<void>;
}

export function createTreeCache(deps: {
  storage: AccountStorage;
  /** Told about the newest snapshot, for the recovery store. */
  onMeta?: (meta: SnapshotMeta) => void;
  /** Told when there is no newest snapshot any more. */
  onMetaCleared?: () => void;
}): TreeCache {
  const { storage } = deps;
  const onMeta = deps.onMeta ?? (() => {});
  const onMetaCleared = deps.onMetaCleared ?? (() => {});

  const cache: TreeCache = {
    cacheTree(model) {
      void cache.writeTree(model);
    },

    async writeTree(model) {
      const written = await storage.putSnapshot({
        initiativeId: model.initiativeId,
        seq: model.seq,
        payload: treePayload(model),
      });
      if (!written.ok) return false;
      const meta: SnapshotMeta = {
        initiativeId: model.initiativeId,
        version: model.header.version,
        seq: model.seq,
        savedAt: written.value.savedAt,
      };
      await storage.putMeta(LAST_SNAPSHOT_KEY, meta);
      onMeta(meta);
      return true;
    },

    async forgetTree(initiativeId) {
      await storage.deleteSnapshot(initiativeId);
      const meta = await storage.getMeta(LAST_SNAPSHOT_KEY);
      const newest = meta.ok ? parseSnapshotMeta(meta.value) : null;
      // The pointer must not outlive what it points at.
      if (newest?.initiativeId === initiativeId) {
        await storage.putMeta(LAST_SNAPSHOT_KEY, null);
        onMetaCleared();
      }
    },

    async readTree(initiativeId) {
      const result = await storage.getSnapshot(initiativeId);
      if (!result.ok || result.value === null) return null;
      const model = parseTreeModel(result.value.payload);
      if (model !== null && model.initiativeId === initiativeId && model.seq === result.value.seq) {
        return model;
      }
      await cache.forgetTree(initiativeId);
      return null;
    },
  };

  return cache;
}
