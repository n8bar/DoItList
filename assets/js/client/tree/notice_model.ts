// What a rejection notice says (m04.02 item 7.14). The API's error prose is
// written for agents — it names ids, keys and indexes — so a person gets one
// plain sentence chosen by the error CODE, and the API's own words go to the
// console. Pure: no DOM, no store.

import type { ApiError } from "../api/client.ts";

export const REJECTED_TITLE = "That change was not saved";

/** The sentence for any code without one of its own. */
export const REJECTED_DEFAULT = "That change was not saved.";

const SENTENCES: Readonly<Record<string, string>> = {
  conflict: "Someone changed this first.",
  duplicate: "That change was already saved.",
  forbidden: "You can't do that here.",
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** The offending op's error, when a batch reply names one. */
function offendingError(error: ApiError): Record<string, unknown> | null {
  const payload = error.payload;
  if (!isRecord(payload) || !Array.isArray(payload["results"])) return null;
  for (const result of payload["results"]) {
    if (isRecord(result) && isRecord(result["error"])) return result["error"];
  }
  return null;
}

/** The code that decides the sentence: the offending op's, else the reply's own. */
export function rejectionCode(error: ApiError): string {
  const code = offendingError(error)?.["code"];
  return typeof code === "string" && code !== "" ? code : error.code;
}

/** The body of a "not saved" notice. */
export function rejectionSentence(error: ApiError): string {
  return SENTENCES[rejectionCode(error)] ?? REJECTED_DEFAULT;
}

/**
 * The body of a refused Undo or Redo. A 422 is the stack's own answer —
 * there was nothing to reverse — said in the stack's terms.
 */
export function historySentence(action: "undo" | "redo", error: ApiError): string {
  const code = rejectionCode(error);
  if (code === "unprocessable_entity") return action === "undo" ? "Nothing to undo." : "Nothing to redo.";
  return SENTENCES[code] ?? REJECTED_DEFAULT;
}

/** The API's own words, for the console: code, status, message, and the op's index and pointer when named. */
export function rejectionDetail(error: ApiError): Record<string, unknown> {
  const offending = offendingError(error);
  const payload = error.payload;
  const results = isRecord(payload) && Array.isArray(payload["results"]) ? payload["results"] : [];
  const index = results.findIndex((r) => isRecord(r) && isRecord(r["error"]));
  return {
    code: rejectionCode(error),
    status: error.status,
    message: typeof offending?.["message"] === "string" ? offending["message"] : error.message,
    ...(index >= 0 ? { index } : {}),
    ...(typeof offending?.["pointer"] === "string" ? { pointer: offending["pointer"] } : {}),
  };
}

/** Logs the API's words where a developer looks, never where a person reads. */
export function warnRejection(what: string, error: ApiError, log: (...args: unknown[]) => void = console.warn): void {
  log(`${what}: the API refused the change`, rejectionDetail(error));
}
