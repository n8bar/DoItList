// Which account this browser profile last held a cache for (m04.01 item 3.6).
//
// The ONLY thing the client keeps in localStorage. It has to live outside
// IndexedDB: the question it answers is "whose database should I be deleting
// before I open mine?", and a database cannot answer that about itself.
//
// It holds an id and nothing else — no name, no email. A profile handed to
// somebody else leaks no more than a number that is already in the page.

export const LAST_USER_KEY = "doit:last_user";

/** The slice of `Storage` we use. Injected so the rules are testable. */
export interface KeyValueStore {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
}

/** The page's localStorage, or `null` where it throws (private mode, blocked). */
export function browserKeyValueStore(): KeyValueStore | null {
  try {
    const store = (globalThis as { localStorage?: KeyValueStore | null }).localStorage;
    return store ?? null;
  } catch {
    return null;
  }
}

export function readLastUser(store: KeyValueStore | null): number | null {
  if (store === null) return null;
  try {
    const raw = store.getItem(LAST_USER_KEY);
    if (raw === null || raw.trim() === "") return null;
    const id = Number(raw);
    return Number.isInteger(id) && id > 0 ? id : null;
  } catch {
    return null;
  }
}

export function writeLastUser(store: KeyValueStore | null, userId: number): void {
  if (store === null) return;
  try {
    store.setItem(LAST_USER_KEY, String(userId));
  } catch {
    // A full or blocked localStorage costs us the marker, not the session.
  }
}

export function clearLastUser(store: KeyValueStore | null): void {
  if (store === null) return;
  try {
    store.removeItem(LAST_USER_KEY);
  } catch {
    // Same: nothing to do, nothing to say.
  }
}

/**
 * Whose cache must be thrown away before this user's is opened.
 *
 * A remembered id that is not the signed-in one means somebody else used this
 * profile — their cache goes, whether or not they logged out cleanly. No
 * marker at all means we cannot know, so the boot sweep (`purgeOtherAccountDbs`)
 * is what protects them.
 */
export function staleAccount(last: number | null, current: number): number | null {
  return last !== null && last !== current ? last : null;
}
