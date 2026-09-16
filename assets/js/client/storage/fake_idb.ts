// A small in-memory IndexedDB, for tests only (m04.01 items 3.4–3.6).
//
// Node 24 has no IndexedDB, so `db.ts` takes its factory as a dependency and
// this is what the suite injects. It implements only what the storage layer
// actually calls, plus the three failures that matter: an open that refuses, a
// write the browser rejects for quota, and a record that comes back corrupt.
//
// Not shipped behaviour — but it is the reason the shipped behaviour is tested
// at all, so it is kept deliberately small and obvious.

import type {
  IdbDatabaseLike,
  IdbFactoryLike,
  IdbObjectStoreLike,
  IdbOpenRequestLike,
  IdbRequestLike,
  IdbTransactionLike,
} from "./idb.ts";

interface FakeStore {
  keyPath: string;
  rows: Map<unknown, unknown>;
}

interface FakeData {
  version: number;
  stores: Map<string, FakeStore>;
}

const clone = <T,>(value: T): T => (value === undefined ? value : (structuredClone(value) as T));

function makeRequest<T>(): IdbRequestLike<T> {
  return { result: undefined as T, error: null, onsuccess: null, onerror: null };
}

class FakeTransaction implements IdbTransactionLike {
  error: { name: string; message: string } | null = null;
  oncomplete: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onabort: (() => void) | null = null;

  private pending = 0;
  private finished = false;
  private readonly data: FakeData;
  private readonly names: string[];
  private readonly idb: FakeIdb;
  private readonly readwrite: boolean;

  // Node's type stripping has no parameter properties, hence the longhand.
  constructor(data: FakeData, names: string[], idb: FakeIdb, readwrite: boolean) {
    this.data = data;
    this.names = names;
    this.idb = idb;
    this.readwrite = readwrite;
    queueMicrotask(() => this.maybeComplete());
  }

  objectStore(name: string): IdbObjectStoreLike {
    if (!this.names.includes(name)) throw new Error(`store ${name} is not in this transaction`);
    const store = this.data.stores.get(name);
    if (store === undefined) throw new Error(`no object store named ${name}`);
    return this.storeHandle(store);
  }

  abort(): void {
    this.fail("AbortError", "aborted");
  }

  private storeHandle(store: FakeStore): IdbObjectStoreLike {
    const run = <T,>(work: () => T, write = false): IdbRequestLike<T> => {
      const req = makeRequest<T>();
      this.pending += 1;
      queueMicrotask(() => {
        this.pending -= 1;
        if (this.finished) return;
        const failure = write ? this.idb.takeWriteFailure() : null;
        if (failure !== null) {
          req.error = failure;
          req.onerror?.();
          this.fail(failure.name, failure.message);
          return;
        }
        try {
          req.result = work();
          req.onsuccess?.();
          this.maybeComplete();
        } catch (error) {
          const message = error instanceof Error ? error.message : "failed";
          req.error = { name: "UnknownError", message };
          req.onerror?.();
          this.fail("UnknownError", message);
        }
      });
      return req;
    };

    const guardWrite = () => {
      if (!this.readwrite) throw new Error("read-only transaction");
    };

    return {
      get: (key) => run(() => clone(store.rows.get(key))),
      getAll: () => run(() => [...store.rows.values()].map((row) => clone(row))),
      put: (value) =>
        run(() => {
          guardWrite();
          const key = (value as Record<string, unknown>)[store.keyPath];
          if (key === undefined) throw new Error("the value has no key");
          store.rows.set(key, clone(value));
          return undefined;
        }, true),
      delete: (key) =>
        run(() => {
          guardWrite();
          store.rows.delete(key);
          return undefined;
        }, true),
      clear: () =>
        run(() => {
          guardWrite();
          store.rows.clear();
          return undefined;
        }, true),
    };
  }

  private fail(name: string, message: string): void {
    if (this.finished) return;
    this.finished = true;
    this.error = { name, message };
    this.onerror?.();
    this.onabort?.();
  }

  private maybeComplete(): void {
    if (this.finished || this.pending > 0) return;
    queueMicrotask(() => {
      if (this.finished || this.pending > 0) return;
      this.finished = true;
      this.oncomplete?.();
    });
  }
}

class FakeDatabase implements IdbDatabaseLike {
  onversionchange: (() => void) | null = null;
  closed = false;

  readonly name: string;
  private readonly data: FakeData;
  private readonly idb: FakeIdb;

  constructor(name: string, data: FakeData, idb: FakeIdb) {
    this.name = name;
    this.data = data;
    this.idb = idb;
  }

  get version(): number {
    return this.data.version;
  }

  get objectStoreNames() {
    return { contains: (name: string) => this.data.stores.has(name) };
  }

  createObjectStore(name: string, options?: { keyPath?: string }): IdbObjectStoreLike {
    const store: FakeStore = { keyPath: options?.keyPath ?? "id", rows: new Map() };
    this.data.stores.set(name, store);
    return new FakeTransaction(this.data, [name], this.idb, true).objectStore(name);
  }

  deleteObjectStore(name: string): void {
    this.data.stores.delete(name);
  }

  transaction(storeNames: string | string[], mode: "readonly" | "readwrite" = "readonly") {
    if (this.closed) throw new Error("the database is closed");
    const names = Array.isArray(storeNames) ? storeNames : [storeNames];
    return new FakeTransaction(this.data, names, this.idb, mode === "readwrite");
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.idb.connectionClosed(this.name);
  }
}

export class FakeIdb implements IdbFactoryLike {
  readonly databasesByName = new Map<string, FakeData>();
  /** Open connections, the way a real browser tracks them. */
  private readonly connections = new Map<string, FakeDatabase[]>();
  /** Deletes waiting for those connections to close, per the IDB spec. */
  private readonly blockedDeletes: { name: string; done: () => void }[] = [];
  /** Set to make the next `open` reject with this DOM error name. */
  openFailure: { name: string; message: string } | null = null;
  /** Set to make `open` never answer, the way a blocked upgrade behaves. */
  openHangs = false;
  /**
   * `databases()` is absent in some browsers (Safari). Constructing with
   * `{ enumerable: false }` removes the method outright rather than leaving one
   * that throws — that is what the storage layer has to cope with.
   */
  databases?: () => Promise<{ name?: string; version?: number }[]>;

  private writeFailures: { name: string; message: string }[] = [];

  constructor(options: { enumerable?: boolean } = {}) {
    if (options.enumerable !== false) {
      this.databases = () =>
        Promise.resolve(
          [...this.databasesByName.entries()].map(([name, data]) => ({
            name,
            version: data.version,
          })),
        );
    }
  }

  /** The next `count` writes fail — quota by default. */
  failWrites(count: number, name = "QuotaExceededError", message = "the quota was exceeded"): void {
    this.writeFailures = Array.from({ length: count }, () => ({ name, message }));
  }

  takeWriteFailure(): { name: string; message: string } | null {
    return this.writeFailures.shift() ?? null;
  }

  /** How many connections are still open — a real `versionchange` blocker. */
  openConnections(name: string): number {
    return (this.connections.get(name) ?? []).filter((db) => !db.closed).length;
  }

  /** Called by a connection closing; retries whatever was waiting on it. */
  connectionClosed(name: string): void {
    this.connections.set(name, (this.connections.get(name) ?? []).filter((db) => !db.closed));
    if (this.openConnections(name) > 0) return;
    for (const pending of this.blockedDeletes.filter((entry) => entry.name === name)) {
      this.blockedDeletes.splice(this.blockedDeletes.indexOf(pending), 1);
      pending.done();
    }
  }

  /** Asks every open connection to get out of the way. */
  private askToClose(name: string): void {
    for (const db of this.connections.get(name) ?? []) {
      if (!db.closed) db.onversionchange?.();
    }
  }

  /** Pre-seeds a database at a given schema version, for migration tests. */
  seedDatabase(name: string, version: number, stores: Record<string, [string, unknown[]]>): void {
    const data: FakeData = { version, stores: new Map() };
    for (const [storeName, [keyPath, rows]] of Object.entries(stores)) {
      const store: FakeStore = { keyPath, rows: new Map() };
      for (const row of rows) store.rows.set((row as Record<string, unknown>)[keyPath], row);
      data.stores.set(storeName, store);
    }
    this.databasesByName.set(name, data);
  }

  /** Writes a row straight in, bypassing validation — for corruption tests. */
  seedRow(dbName: string, storeName: string, key: unknown, row: unknown): void {
    this.databasesByName.get(dbName)?.stores.get(storeName)?.rows.set(key, row);
  }

  rows(dbName: string, storeName: string): unknown[] {
    return [...(this.databasesByName.get(dbName)?.stores.get(storeName)?.rows.values() ?? [])];
  }

  open(name: string, version = 1): IdbOpenRequestLike {
    const req: IdbOpenRequestLike = {
      result: undefined as unknown as IdbDatabaseLike,
      error: null,
      onsuccess: null,
      onerror: null,
      onupgradeneeded: null,
      onblocked: null,
      transaction: null,
    };

    queueMicrotask(() => {
      if (this.openHangs) return;
      if (this.openFailure !== null) {
        req.error = this.openFailure;
        req.onerror?.();
        return;
      }

      const existing = this.databasesByName.get(name);
      const data: FakeData = existing ?? { version: 0, stores: new Map() };
      if (existing === undefined) this.databasesByName.set(name, data);

      if (version < data.version) {
        req.error = { name: "VersionError", message: "a newer schema is already here" };
        req.onerror?.();
        return;
      }

      if (version > data.version) {
        // An upgrade waits for the other connections, and says so if they stay.
        this.askToClose(name);
        if (this.openConnections(name) > 0) {
          req.onblocked?.();
          return;
        }
      }

      const db = new FakeDatabase(name, data, this);
      this.connections.set(name, [...(this.connections.get(name) ?? []), db]);
      req.result = db;

      if (version > data.version) {
        const oldVersion = data.version;
        data.version = version;
        const tx = new FakeTransaction(data, [...data.stores.keys()], this, true);
        req.transaction = {
          objectStore: (storeName: string) =>
            new FakeTransaction(data, [storeName], this, true).objectStore(storeName),
          abort: () => tx.abort(),
          error: null,
          oncomplete: null,
          onerror: null,
          onabort: null,
        };
        req.onupgradeneeded?.({ oldVersion, newVersion: version });
        req.transaction = null;
      }

      req.onsuccess?.();
    });

    return req;
  }

  deleteDatabase(name: string): IdbRequestLike<unknown> {
    const req = makeRequest<unknown>();
    const finish = () => {
      this.databasesByName.delete(name);
      this.connections.delete(name);
      req.onsuccess?.();
    };

    queueMicrotask(() => {
      // Exactly like the real thing: every open connection is told, and the
      // delete blocks until they are all gone.
      this.askToClose(name);
      if (this.openConnections(name) > 0) {
        this.blockedDeletes.push({ name, done: finish });
        return;
      }
      finish();
    });

    return req;
  }

}
