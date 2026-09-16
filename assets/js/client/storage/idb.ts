// The narrow slice of IndexedDB this client uses (m04.01 items 3.4–3.6).
//
// The storage layer never touches `globalThis.indexedDB` directly: it is handed
// a factory. That is not ceremony — Node 24 has no IndexedDB, so every rule
// below (schema upgrades, account isolation, bounds, quota, corruption) is unit
// tested against `fake_idb.ts` instead of being discovered in a browser.
//
// These are structural interfaces, not the DOM's. The real `indexedDB` is cast
// to `IdbFactoryLike` in exactly one place (`browserIdb`), which keeps the fake
// honest-sized instead of forcing it to re-implement DOM event objects.

export interface IdbRequestLike<T> {
  result: T;
  error: { readonly name: string; readonly message: string } | null;
  onsuccess: (() => void) | null;
  onerror: (() => void) | null;
}

export interface IdbUpgradeEvent {
  readonly oldVersion: number;
  readonly newVersion: number | null;
}

export interface IdbOpenRequestLike extends IdbRequestLike<IdbDatabaseLike> {
  onupgradeneeded: ((event: IdbUpgradeEvent) => void) | null;
  onblocked: (() => void) | null;
  /** The upgrade transaction, live only while `onupgradeneeded` is running. */
  transaction: IdbTransactionLike | null;
}

export interface IdbObjectStoreLike {
  get(key: unknown): IdbRequestLike<unknown>;
  getAll(): IdbRequestLike<unknown[]>;
  put(value: unknown): IdbRequestLike<unknown>;
  delete(key: unknown): IdbRequestLike<unknown>;
  clear(): IdbRequestLike<unknown>;
}

export interface IdbTransactionLike {
  objectStore(name: string): IdbObjectStoreLike;
  abort(): void;
  error: { readonly name: string; readonly message: string } | null;
  oncomplete: (() => void) | null;
  onerror: (() => void) | null;
  onabort: (() => void) | null;
}

export interface IdbDatabaseLike {
  readonly name: string;
  readonly version: number;
  readonly objectStoreNames: { contains(name: string): boolean };
  createObjectStore(name: string, options?: { keyPath?: string }): IdbObjectStoreLike;
  deleteObjectStore(name: string): void;
  transaction(storeNames: string | string[], mode?: "readonly" | "readwrite"): IdbTransactionLike;
  close(): void;
  onversionchange: (() => void) | null;
}

export interface IdbFactoryLike {
  open(name: string, version?: number): IdbOpenRequestLike;
  deleteDatabase(name: string): IdbRequestLike<unknown>;
  /** Not in Safari. Absent means "we cannot enumerate", never "there is nothing". */
  databases?(): Promise<{ name?: string | undefined; version?: number | undefined }[]>;
}

/** A named failure, so callers can branch on `quota` without matching strings. */
export class IdbError extends Error {
  override readonly name: string;

  constructor(name: string, message: string) {
    super(message);
    this.name = name;
  }
}

const failure = (error: { name: string; message: string } | null, fallback: string): IdbError =>
  new IdbError(error?.name ?? "UnknownError", error?.message ?? fallback);

/** One request as a promise. Rejects with an `IdbError` carrying the DOM name. */
export function request<T>(req: IdbRequestLike<T>): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(failure(req.error, "The database request failed."));
  });
}

/** Resolves when the transaction commits; rejects if it errors or aborts. */
export function committed(tx: IdbTransactionLike): Promise<void> {
  return new Promise<void>((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(failure(tx.error, "The database transaction failed."));
    tx.onabort = () => reject(failure(tx.error, "The database transaction was aborted."));
  });
}

/**
 * The page's IndexedDB, or `null` where there isn't one (private mode in some
 * browsers removes it outright). The single cast in the client.
 */
export function browserIdb(): IdbFactoryLike | null {
  try {
    const factory = (globalThis as { indexedDB?: unknown }).indexedDB;
    return factory === undefined || factory === null ? null : (factory as IdbFactoryLike);
  } catch {
    // Some privacy modes throw on the property access itself.
    return null;
  }
}
