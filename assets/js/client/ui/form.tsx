// Form primitives (item 4.2, UX_GUARDRAILS §2, §4.1).
//
// Every field is the same three things: a real `<label for>`, the control, and
// — when they exist — a description and an error that the control POINTS AT
// through `aria-describedby` (`form_model.ts`). Loose text near an input is not
// a label and is not an error; it is text near an input.
//
// The rules these encode:
//   * an error appears next to its field, never as a banner (§2.2);
//   * the field keeps what the user typed when the write is rejected (§2.1) —
//     the caller holds the values, so a rejection never clears them;
//   * a submit acknowledges instantly and keeps its size while it does (§6.7,
//     item 4.6): the button says "Saving…" in the same box it said "Save" in.
//
// Styling is the frame's, not daisyUI's: the same zinc/emerald palette, the
// same rounded-lg, the same emerald focus ring, in both themes.

import type { ChangeEvent, ReactNode } from "react";

import { actionClass } from "../frame/button_styles.ts";
import type { FieldIds } from "./form_model.ts";
import { SAVING_LABEL, describedBy, fieldIds } from "./form_model.ts";
import { Icon } from "./icon.tsx";

const CONTROL = [
  "w-full min-h-11 rounded-lg border px-3 py-2 text-sm",
  "border-zinc-300 bg-white text-zinc-900 placeholder:text-zinc-400",
  "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-emerald-600",
  "dark:border-zinc-600 dark:bg-zinc-900 dark:text-zinc-100 dark:placeholder:text-zinc-500",
  "dark:focus-visible:ring-emerald-400",
  "sm:min-h-9",
].join(" ");

const CONTROL_ERROR = "border-red-500 dark:border-red-500";

const LABEL = "block text-sm font-medium text-zinc-800 dark:text-zinc-200";

export interface FieldProps {
  /** The form's id. Every id inside the field is derived from it plus `name`. */
  formId: string;
  name: string;
  label: string;
  /** A plain sentence about what goes in here. */
  description?: string;
  /** The reason the last attempt was rejected, in the user's terms. */
  error?: string | null;
  required?: boolean;
  children: (field: { ids: FieldIds; describedBy: string | undefined; invalid: boolean }) => ReactNode;
}

/**
 * The label / control / description / error frame. A render prop, so a field
 * can hold any control — including one a later arc invents — without this
 * module having to know about it.
 */
export function Field({
  formId,
  name,
  label,
  description,
  error,
  required,
  children,
}: FieldProps) {
  const ids = fieldIds(formId, name);
  const hasError = error !== undefined && error !== null && error !== "";
  const hasDescription = description !== undefined && description !== "";

  return (
    <div className="mb-4">
      <label htmlFor={ids.inputId} className={LABEL}>
        {label}
        {required === true && (
          <span className="ml-1 text-zinc-500 dark:text-zinc-400" aria-hidden="true">
            *
          </span>
        )}
      </label>

      <div className="mt-1">
        {children({
          ids,
          describedBy: describedBy(ids, { description: hasDescription, error: hasError }),
          invalid: hasError,
        })}
      </div>

      {hasDescription && (
        <p id={ids.descriptionId} className="mt-1 text-xs text-zinc-500 dark:text-zinc-400">
          {description}
        </p>
      )}

      {hasError && (
        <p
          id={ids.errorId}
          className="mt-1.5 flex items-center gap-1.5 text-sm text-red-700 dark:text-red-300"
        >
          <Icon name="exclamation-circle" className="size-5 flex-none" />
          {error}
        </p>
      )}
    </div>
  );
}

interface ControlProps {
  formId: string;
  name: string;
  label: string;
  description?: string;
  error?: string | null;
  required?: boolean;
  disabled?: boolean;
  placeholder?: string;
}

export interface TextInputProps extends ControlProps {
  value: string;
  onChange: (value: string) => void;
  type?: "text" | "email" | "url" | "search" | "password";
}

export function TextInput({ value, onChange, type = "text", ...rest }: TextInputProps) {
  return (
    <Field {...rest}>
      {({ ids, describedBy: described, invalid }) => (
        <input
          type={type}
          id={ids.inputId}
          name={rest.name}
          value={value}
          required={rest.required === true}
          disabled={rest.disabled === true}
          aria-invalid={invalid}
          {...(described === undefined ? {} : { "aria-describedby": described })}
          {...(rest.placeholder === undefined ? {} : { placeholder: rest.placeholder })}
          className={`${CONTROL}${invalid ? ` ${CONTROL_ERROR}` : ""}`}
          onChange={(event: ChangeEvent<HTMLInputElement>) => onChange(event.target.value)}
        />
      )}
    </Field>
  );
}

export interface TextAreaProps extends ControlProps {
  value: string;
  onChange: (value: string) => void;
  rows?: number;
}

export function TextArea({ value, onChange, rows = 4, ...rest }: TextAreaProps) {
  return (
    <Field {...rest}>
      {({ ids, describedBy: described, invalid }) => (
        <textarea
          id={ids.inputId}
          name={rest.name}
          value={value}
          rows={rows}
          required={rest.required === true}
          disabled={rest.disabled === true}
          aria-invalid={invalid}
          {...(described === undefined ? {} : { "aria-describedby": described })}
          {...(rest.placeholder === undefined ? {} : { placeholder: rest.placeholder })}
          className={`${CONTROL} resize-y${invalid ? ` ${CONTROL_ERROR}` : ""}`}
          onChange={(event: ChangeEvent<HTMLTextAreaElement>) => onChange(event.target.value)}
        />
      )}
    </Field>
  );
}

export interface SelectOption {
  readonly value: string;
  readonly label: string;
}

export interface SelectProps extends ControlProps {
  value: string;
  onChange: (value: string) => void;
  options: readonly SelectOption[];
  /** A first, empty option — "Choose a…" — when nothing is chosen yet. */
  prompt?: string;
}

export function Select({ value, onChange, options, prompt, ...rest }: SelectProps) {
  return (
    <Field {...rest}>
      {({ ids, describedBy: described, invalid }) => (
        <select
          id={ids.inputId}
          name={rest.name}
          value={value}
          required={rest.required === true}
          disabled={rest.disabled === true}
          aria-invalid={invalid}
          {...(described === undefined ? {} : { "aria-describedby": described })}
          className={`${CONTROL}${invalid ? ` ${CONTROL_ERROR}` : ""}`}
          onChange={(event: ChangeEvent<HTMLSelectElement>) => onChange(event.target.value)}
        >
          {prompt !== undefined && <option value="">{prompt}</option>}
          {options.map((option) => (
            <option key={option.value} value={option.value}>
              {option.label}
            </option>
          ))}
        </select>
      )}
    </Field>
  );
}

export interface CheckboxProps {
  formId: string;
  name: string;
  label: string;
  description?: string;
  error?: string | null;
  disabled?: boolean;
  checked: boolean;
  onChange: (checked: boolean) => void;
}

/**
 * A checkbox labels itself on its right, so the label and the box are one
 * target — and the whole row is at least 44px tall for a thumb (§5.1).
 */
export function Checkbox({
  formId,
  name,
  label,
  description,
  error,
  disabled,
  checked,
  onChange,
}: CheckboxProps) {
  const ids = fieldIds(formId, name);
  const hasError = error !== undefined && error !== null && error !== "";
  const hasDescription = description !== undefined && description !== "";
  const described = describedBy(ids, { description: hasDescription, error: hasError });

  return (
    <div className="mb-4">
      <label
        htmlFor={ids.inputId}
        className="flex min-h-11 cursor-pointer items-center gap-2 text-sm text-zinc-800 dark:text-zinc-200 sm:min-h-9"
      >
        <input
          type="checkbox"
          id={ids.inputId}
          name={name}
          checked={checked}
          disabled={disabled === true}
          aria-invalid={hasError}
          {...(described === undefined ? {} : { "aria-describedby": described })}
          className="size-5 flex-none rounded border-zinc-300 text-emerald-600 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-emerald-600 dark:border-zinc-600 dark:focus-visible:ring-emerald-400"
          onChange={(event: ChangeEvent<HTMLInputElement>) => onChange(event.target.checked)}
        />
        {label}
      </label>

      {hasDescription && (
        <p id={ids.descriptionId} className="mt-1 text-xs text-zinc-500 dark:text-zinc-400">
          {description}
        </p>
      )}
      {hasError && (
        <p
          id={ids.errorId}
          className="mt-1.5 flex items-center gap-1.5 text-sm text-red-700 dark:text-red-300"
        >
          <Icon name="exclamation-circle" className="size-5 flex-none" />
          {error}
        </p>
      )}
    </div>
  );
}

export interface SubmitButtonProps {
  id: string;
  /** What it says when it is not busy. A verb. */
  label: string;
  /** The write is in flight: the press is already acknowledged (§6.7). */
  busy?: boolean;
  disabled?: boolean;
  variant?: "primary" | "danger";
}

/**
 * The submit control. While the write is in flight it says so IN THE SAME BOX:
 * `min-w-32` holds the width, so "Save" becoming "Saving…" cannot resize the
 * button or shuffle the row it sits in (item 4.6).
 */
export function SubmitButton({
  id,
  label,
  busy = false,
  disabled = false,
  variant = "primary",
}: SubmitButtonProps) {
  const off = busy || disabled;

  return (
    <button
      type="submit"
      id={id}
      disabled={off}
      aria-busy={busy}
      className={`${actionClass({ variant, ...(off ? { disabled: true } : {}) })} min-w-32`}
    >
      {busy && <Icon name="arrow-path" spin />}
      {busy ? SAVING_LABEL : label}
    </button>
  );
}
