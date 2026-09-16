// The parts of a form that are rules, not markup (item 4.2).
//
// Two things live here, both testable without a DOM:
//
//   * the id wiring that makes a field's description and its error part of the
//     input's accessible description rather than loose text near it
//     (guardrails §4.1) — an error nobody's screen reader reads is an error
//     they will hit again;
//   * the translation from the server's per-op failure into "this field, this
//     message", so a rejected write lands NEXT TO the field that caused it
//     (§2.2) instead of as a banner at the top of the form.
//
// The wire shape is `DoItWeb.Api.Operations`': a batch reply carries `results`,
// and the offending op's `error` carries `code`, `message` and an optional
// `pointer` naming the field. A single-error response carries the same shape
// under `error`.

export interface FieldIds {
  readonly inputId: string;
  readonly descriptionId: string;
  readonly errorId: string;
}

export function fieldIds(formId: string, name: string): FieldIds {
  return {
    inputId: `${formId}-${name}`,
    descriptionId: `${formId}-${name}-description`,
    errorId: `${formId}-${name}-error`,
  };
}

/**
 * The `aria-describedby` for an input: its description, then its error, in the
 * order they should be heard. `undefined` when it has neither — an empty
 * `aria-describedby` points at nothing and reads as a bug.
 */
export function describedBy(
  ids: FieldIds,
  has: { description: boolean; error: boolean },
): string | undefined {
  const parts = [
    has.description ? ids.descriptionId : null,
    has.error ? ids.errorId : null,
  ].filter((part): part is string => part !== null);

  return parts.length === 0 ? undefined : parts.join(" ");
}

/** What a submit button says while its write is in flight (§6.7). */
export const SAVING_LABEL = "Saving…";

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

/** A `{pointer, message}` pair, when the error carries a usable one. */
function pointerError(value: unknown): { field: string; message: string } | null {
  if (!isRecord(value)) return null;
  const pointer = value["pointer"];
  const message = value["message"];
  if (typeof pointer !== "string" || pointer === "") return null;
  if (typeof message !== "string" || message === "") return null;
  return { field: pointer, message };
}

/**
 * Field errors from a rejected response body, keyed by field name. The first
 * error wins for a field: the batch rolled back at the first failure, so that
 * is the one the user has to fix.
 *
 * Anything it cannot read gives `{}` — a form that cannot place an error shows
 * it as a form-level message instead, never swallows it.
 */
export function fieldErrorsFrom(payload: unknown): Record<string, string> {
  const errors: Record<string, string> = {};
  if (!isRecord(payload)) return errors;

  const results = payload["results"];
  if (Array.isArray(results)) {
    for (const result of results) {
      if (!isRecord(result)) continue;
      const found = pointerError(result["error"]);
      if (found !== null && errors[found.field] === undefined) errors[found.field] = found.message;
    }
  }

  const top = pointerError(payload["error"]);
  if (top !== null && errors[top.field] === undefined) errors[top.field] = top.message;

  return errors;
}

/**
 * What a form says when the submit never came back with an answer at all — the
 * promise rejected rather than resolving to a `Result`. A dropped connection, a
 * refused write, a bug in the caller: from the user's seat it is the same, and
 * the one thing they must not be left with is a button that stays busy forever
 * (§6.7).
 */
export const SUBMIT_REJECTED = "Couldn’t save that. Try again.";

/**
 * The form-level message for a rejected submit. Never a field message: nothing
 * in a rejection says which field was at fault, and guessing would send the
 * user to edit a value that was fine.
 */
export function rejectionMessage(reason: unknown): string {
  if (reason instanceof Error && reason.message !== "") return reason.message;
  if (typeof reason === "string" && reason !== "") return reason;
  return SUBMIT_REJECTED;
}
