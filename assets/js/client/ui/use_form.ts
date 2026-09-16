// `useForm` (item 4.2).
//
// The small amount of state every form in this client needs, and the rules that
// are easy to get wrong:
//
//   * the press is acknowledged the instant it happens — `busy` is true before
//     the request leaves (§6.7), and a second press while it is in flight is
//     ignored rather than queued;
//   * a rejection NEVER clears what the user typed (§2.1): the values are this
//     hook's state and a failure only adds errors to them;
//   * a rejection's per-op `pointer` errors land on their fields (§2.2,
//     `fieldErrorsFrom`), and whatever cannot be placed on a field becomes the
//     form-level message rather than being swallowed;
//   * a submit that rejects outright ends the press too: `busy` clears and the
//     failure becomes a form-level message, because a form stuck on "Saving…"
//     is the one failure the user cannot get out of;
//   * editing a field clears that field's error — the error described the value
//     the user has just changed.

import { useCallback, useRef, useState } from "react";

import type { ApiError, Result } from "../api/client.ts";
import { fieldErrorsFrom, rejectionMessage } from "./form_model.ts";

export type FormValues = Record<string, string | boolean>;

export interface UseFormOptions<V extends FormValues, T> {
  /** The starting values. Also what `reset()` goes back to. */
  initial: V;
  /** Sends the write. The one round trip in a form's life. */
  submit: (values: V) => Promise<Result<T>>;
  onSuccess?: (data: T, values: V) => void;
  /** Called for a failure the form could not place on any field. */
  onError?: (error: ApiError) => void;
}

export interface FormApi<V extends FormValues> {
  readonly values: V;
  setValue<K extends keyof V>(name: K, value: V[K]): void;
  /** Per-field messages, keyed by field name. */
  readonly errors: Readonly<Record<string, string>>;
  /** The failure that belongs to no single field, or `null`. */
  readonly formError: string | null;
  /** A write is in flight. */
  readonly busy: boolean;
  /** Submit handler for `<form onSubmit>`. */
  onSubmit(event: { preventDefault(): void }): void;
  reset(): void;
}

export function useForm<V extends FormValues, T>(options: UseFormOptions<V, T>): FormApi<V> {
  const [values, setValues] = useState<V>(options.initial);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [formError, setFormError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  // The options object is rebuilt every render; the handlers must not be.
  const latest = useRef(options);
  latest.current = options;

  const setValue = useCallback(<K extends keyof V>(name: K, value: V[K]) => {
    setValues((current) => ({ ...current, [name]: value }));
    setErrors((current) => {
      if (current[String(name)] === undefined) return current;
      const next = { ...current };
      delete next[String(name)];
      return next;
    });
  }, []);

  const reset = useCallback(() => {
    setValues(latest.current.initial);
    setErrors({});
    setFormError(null);
  }, []);

  const onSubmit = useCallback(
    (event: { preventDefault(): void }) => {
      event.preventDefault();
      if (busy) return;

      setBusy(true);
      setErrors({});
      setFormError(null);

      const sent = { ...values };
      void latest.current
        .submit(sent as V)
        .then((result) => {
          setBusy(false);
          if (result.ok) {
            latest.current.onSuccess?.(result.data, sent as V);
            return;
          }

          const fields = fieldErrorsFrom(result.error.payload);
          setErrors(fields);
          // Placed on a field, or said out loud — never neither.
          if (Object.keys(fields).length === 0) setFormError(result.error.message);
          latest.current.onError?.(result.error);
        })
        .catch((reason: unknown) => {
          // The submit never came back with an answer at all. Leaving `busy`
          // set would wedge the form for good, so the press ends here and says
          // so — form-level, because nothing here points at a field (§6.7).
          setBusy(false);
          setFormError(rejectionMessage(reason));
        });
    },
    [busy, values],
  );

  return { values, setValue, errors, formError, busy, onSubmit, reset };
}
