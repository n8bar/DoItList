// The Initiative header's decisions (m04.02 7.10), apart from its markup: what
// the badge counts, what a name or subtitle edit sends, and how the reply and
// a refusal land on the header the screen holds.

import type { InitiativeHeader, TreeModel } from "../tree/model.ts";
import { doneUnitCount, unitCount } from "../tree/progress.ts";

/** `initiative_header/1`'s copy, verbatim. */
export const EDIT_NAME_LABEL = "Edit initiative name";
export const EDIT_NAME_TITLE = "Edit name";
export const EDIT_SUBTITLE_TITLE = "Click to edit";

export interface HeaderCounts {
  readonly total: number;
  readonly done: number;
}

/** The system root's units — the header badge's numbers, from the tree as shown. */
export function headerCounts(model: TreeModel): HeaderCounts {
  return { total: unitCount(model, model.rootId), done: doneUnitCount(model, model.rootId) };
}

/** What the header's click-to-edit fields can change. */
export interface HeaderFields {
  readonly name?: string;
  readonly subtitle?: string;
}

export interface HeaderEditRequest {
  operations: [
    {
      op: "update";
      type: "initiative";
      id: number;
      data: { name?: string; subtitle?: string; expected_version: number };
    },
  ];
}

export interface HeaderEdit {
  /** The header as it will read once the write lands — shown at once (§6). */
  readonly next: InitiativeHeader;
  readonly request: HeaderEditRequest;
}

/**
 * One `update initiative` for what actually changed, or `null` when nothing
 * did. A blank name is not a change: the workspace's form refuses it, so the
 * header keeps the name it had. A blank subtitle clears it (the model holds
 * `null` for none; the server stores the root's title as a space).
 */
export function headerEdit(header: InitiativeHeader, fields: HeaderFields): HeaderEdit | null {
  const data: { name?: string; subtitle?: string } = {};
  let next: InitiativeHeader = header;

  if (fields.name !== undefined) {
    const name = fields.name.trim();
    if (name !== "" && name !== header.name) {
      data.name = name;
      next = { ...next, name };
    }
  }
  if (fields.subtitle !== undefined) {
    const subtitle = fields.subtitle.trim();
    if (subtitle !== (header.subtitle ?? "")) {
      data.subtitle = subtitle;
      next = { ...next, subtitle: subtitle === "" ? null : subtitle };
    }
  }
  if (next === header) return null;

  return {
    next,
    request: {
      operations: [
        {
          op: "update",
          type: "initiative",
          id: header.id,
          data: { ...data, expected_version: header.version },
        },
      ],
    },
  };
}

/**
 * The reply's `initiative` result — its name and version — on the header. The
 * subtitle is not echoed (it is the root task's title), so the prediction's
 * stands until the next read. An unreadable reply leaves the header as it is.
 */
export function adoptHeaderReply(header: InitiativeHeader, payload: unknown): InitiativeHeader {
  if (typeof payload !== "object" || payload === null) return header;
  const results = (payload as { results?: unknown }).results;
  if (!Array.isArray(results) || results.length === 0) return header;
  const first = results[0] as { type?: unknown; data?: unknown };
  if (first.type !== "initiative") return header;
  const data = (typeof first.data === "object" && first.data !== null ? first.data : {}) as {
    name?: unknown;
    version?: unknown;
  };
  let next = header;
  if (typeof data.name === "string" && data.name !== next.name) next = { ...next, name: data.name };
  if (typeof data.version === "number" && data.version !== next.version) {
    next = { ...next, version: data.version };
  }
  return next;
}

/**
 * A refused edit goes back to what the header read before it — only the
 * fields the edit touched, so anything that arrived since (a version, a
 * progress) is kept.
 */
export function revertHeader(
  current: InitiativeHeader,
  prior: InitiativeHeader,
  fields: HeaderFields,
): InitiativeHeader {
  let next = current;
  if (fields.name !== undefined && next.name !== prior.name) next = { ...next, name: prior.name };
  if (fields.subtitle !== undefined && next.subtitle !== prior.subtitle) {
    next = { ...next, subtitle: prior.subtitle };
  }
  return next;
}
