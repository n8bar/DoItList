// Tiny assertion helper for the React client. Pure, dependency-free, and
// importable by `node --test` under Node's built-in type stripping, so its
// unit suite needs no build step.

/**
 * Throws when `condition` is falsy. Narrows the condition for TypeScript so
 * callers can rely on it afterwards.
 */
export function invariant(condition: unknown, message: string): asserts condition {
  if (!condition) {
    throw new InvariantError(message);
  }
}

export class InvariantError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "InvariantError";
  }
}
