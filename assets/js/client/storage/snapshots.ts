// What a cached Initiative is, and who writes it (m04.01 items 3.4, 3.6).
//
// Only the header is cached, not the task tree: this arc renders the header,
// and a recovery cache should hold what the client can honestly show, not a
// copy of the whole database (spec §5). Arc 2 widens the payload when it has a
// tree to draw; the record shape and the bounds already allow for it.
//
// Every write is fire-and-forget on purpose. Caching is a courtesy to the next
// page load — a user's action must never wait on it (UX_GUARDRAILS §6).

import type { InitiativeTree, Role } from "../api/types.ts";
import type { AccountStorage } from "./db.ts";

export const LAST_SNAPSHOT_KEY = "last_snapshot";

/** The Initiative header, exactly as the screen shows it. */
export interface InitiativeSnapshot {
  readonly id: number;
  readonly name: string;
  readonly subtitle: string | null;
  readonly role: Role;
  readonly progress: number;
  readonly unit_count: number;
  readonly version: number;
}

/** Which Initiative the newest snapshot covers. Mirrored into the recovery store. */
export interface SnapshotMeta {
  readonly initiativeId: number;
  readonly version: number;
  readonly savedAt: number;
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

export function treeSummary(tree: InitiativeTree): InitiativeSnapshot {
  return {
    id: tree.id,
    name: tree.name,
    subtitle: tree.subtitle,
    role: tree.role,
    progress: tree.progress,
    unit_count: tree.unit_count,
    version: tree.version,
  };
}

export function parseInitiativeSnapshot(value: unknown): InitiativeSnapshot | null {
  if (!isRecord(value)) return null;
  const { id, name, subtitle, role, progress, unit_count, version } = value;
  if (
    typeof id !== "number" ||
    typeof name !== "string" ||
    typeof progress !== "number" ||
    typeof unit_count !== "number" ||
    typeof version !== "number"
  ) {
    return null;
  }
  return {
    id,
    name,
    subtitle: typeof subtitle === "string" ? subtitle : null,
    role: (typeof role === "string" ? role : "viewer") as Role,
    progress,
    unit_count,
    version,
  };
}

export function parseSnapshotMeta(value: unknown): SnapshotMeta | null {
  if (!isRecord(value)) return null;
  const { initiativeId, version, savedAt } = value;
  if (
    typeof initiativeId !== "number" ||
    typeof version !== "number" ||
    typeof savedAt !== "number"
  ) {
    return null;
  }
  return { initiativeId, version, savedAt };
}

export interface TreeCache {
  /** Caches a tree the server just confirmed. Never throws, never awaited. */
  cacheTree(tree: InitiativeTree): void;
  /** The same write, awaitable — for callers that must know when it landed. */
  writeTree(tree: InitiativeTree): Promise<boolean>;
  /** The last copy saved on this device, or `null`. Never throws. */
  readTree(initiativeId: number): Promise<InitiativeSnapshot | null>;
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
    cacheTree(tree) {
      void cache.writeTree(tree);
    },

    async writeTree(tree) {
      const written = await storage.putSnapshot({
        initiativeId: tree.id,
        seq: tree.version,
        payload: treeSummary(tree),
      });
      if (!written.ok) return false;
      const meta: SnapshotMeta = {
        initiativeId: tree.id,
        version: tree.version,
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
      return parseInitiativeSnapshot(result.value.payload);
    },
  };

  return cache;
}
