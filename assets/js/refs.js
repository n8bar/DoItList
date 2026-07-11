// Pure, DOM-free core for the %-notation cross-reference feature.
//
// No imports, no DOM, no side effects — just string transforms over the
// three text shapes we deal with:
//
//   * user-typed text : prose + `%path` refs + `\`-escapes + literal `%`
//   * stored text     : prose + `%<id>` resolved tokens + `\`-escapes
//   * edit-box text    : rehydrated stored text (tokens shown as `%path`)
//
// A resolved reference is stored/broadcast as `%<id>` where the brackets are
// ASCII `<` / `>` and `id` is an integer task id, e.g. `%<272>`.
// The ASCII form is typable, so user-typed text CAN contain a literal `%<id>`;
// `<` is not a path char, so it passes through save verbatim — and then reads
// back as a live token. Typing the raw token form IS writing a ref by id.
//
// Escaping is a recursive backslash: `\` makes the NEXT char literal, but is
// only significant before `%` or `\`. Before any other char the backslash is
// itself a literal char (so `C:\path` stays `C:\path`). Escapes are carried
// verbatim in stored/edit text and only resolved to literal chars at render
// time (see `segments`).

const OPEN = "<";
const CLOSE = ">";

// A dotted-decimal reference path: `\d+(?:\.\d+)*`, anchored at `pos`.
// Returns the matched path string, or null if there is no path at `pos`.
function matchPathAt(text, pos) {
  const re = /\d+(?:\.\d+)*/y;
  re.lastIndex = pos;
  const m = re.exec(text);
  return m ? m[0] : null;
}

// A resolved-token body `<id>` (brackets included), anchored at `pos` (the
// char just after `%`).
// Returns `{ id, length }` (length of the bracketed body) or null.
function matchTokenAt(text, pos) {
  const re = new RegExp(OPEN + "(\\d+)" + CLOSE, "y");
  re.lastIndex = pos;
  const m = re.exec(text);
  return m ? { id: Number(m[1]), length: m[0].length } : null;
}

// Consume a backslash escape at `text[i]` (already known to be `\`).
// Returns `{ chunk, advance }` where `chunk` is the verbatim (backslashes
// preserved) representation and `advance` is how many chars were consumed.
// `\%` and `\\` are two-char escapes; a lone `\` before anything else stays a
// single literal backslash.
function verbatimEscape(text, i) {
  const next = text[i + 1];
  if (next === "%" || next === "\\") {
    return { chunk: "\\" + next, advance: 2 };
  }
  return { chunk: "\\", advance: 1 };
}

/**
 * transformForSave(text, resolve)
 *
 * `text` is user-typed. For each UNescaped `%path`, call
 * `resolve(path)`; a returned id replaces `%path` with `%<id>`, a null leaves
 * the literal `%path` verbatim. Escaped sequences and non-ref `%` are left
 * verbatim (backslashes preserved).
 *
 * @param {string} text
 * @param {(path: string) => number|null} resolve
 * @returns {string}
 */
export function transformForSave(text, resolve) {
  let out = "";
  let i = 0;
  const n = text.length;
  while (i < n) {
    const c = text[i];
    if (c === "\\") {
      const esc = verbatimEscape(text, i);
      out += esc.chunk;
      i += esc.advance;
    } else if (c === "%") {
      const path = matchPathAt(text, i + 1);
      if (path !== null) {
        const id = resolve(path);
        out += id == null ? "%" + path : "%" + OPEN + id + CLOSE;
        i += 1 + path.length;
      } else {
        out += "%"; // literal percent
        i += 1;
      }
    } else {
      out += c;
      i += 1;
    }
  }
  return out;
}

/**
 * rehydrate(text, labelOf)
 *
 * `text` is stored (may contain `%<id>` tokens + escapes + prose). Replace each
 * `%<id>` with `%` + labelOf(id); when labelOf(id) is null (target gone) use
 * `%?` (a visible, editable placeholder — the raw id is never exposed). Escapes
 * and prose are left verbatim. An escaped `\%<id>` is a literal percent, not a
 * token, and is preserved as-is.
 *
 * @param {string} text
 * @param {(id: number) => string|null} labelOf
 * @returns {string}
 */
export function rehydrate(text, labelOf) {
  let out = "";
  let i = 0;
  const n = text.length;
  while (i < n) {
    const c = text[i];
    if (c === "\\") {
      const esc = verbatimEscape(text, i);
      out += esc.chunk;
      i += esc.advance;
    } else if (c === "%") {
      const t = matchTokenAt(text, i + 1);
      if (t) {
        const label = labelOf(t.id);
        out += label == null ? "%?" : "%" + label;
        i += 1 + t.length;
      } else {
        out += "%"; // bare percent or unresolved literal %path
        i += 1;
      }
    } else {
      out += c;
      i += 1;
    }
  }
  return out;
}

/**
 * collectRefs(text)
 *
 * `text` is user-typed. Returns `{ path, index }` for each UNescaped `%path`,
 * where `index` is the char offset of the `%`. Escaped `\%` and bare `%` are
 * skipped. Callers resolve/label — this just finds them.
 *
 * @param {string} text
 * @returns {{ path: string, index: number }[]}
 */
export function collectRefs(text) {
  const refs = [];
  let i = 0;
  const n = text.length;
  while (i < n) {
    const c = text[i];
    if (c === "\\") {
      i += verbatimEscape(text, i).advance;
    } else if (c === "%") {
      const path = matchPathAt(text, i + 1);
      if (path !== null) {
        refs.push({ path, index: i });
        i += 1 + path.length;
      } else {
        i += 1;
      }
    } else {
      i += 1;
    }
  }
  return refs;
}

/**
 * segments(text)
 *
 * `text` is stored (tokens + escapes + prose). Returns an ordered array of
 * `{ type: 'text', value }` literal runs (escapes RESOLVED: `\%`→`%`, `\\`→`\`,
 * `\x`→`\x`) and `{ type: 'ref', id }` for each `%<id>`. A bare literal `%` is
 * part of a text run. This is the DOM-free basis a renderer builds on.
 *
 * @param {string} text
 * @returns {({ type: 'text', value: string } | { type: 'ref', id: number })[]}
 */
export function segments(text) {
  const segs = [];
  let run = "";
  const flush = () => {
    if (run.length > 0) {
      segs.push({ type: "text", value: run });
      run = "";
    }
  };
  let i = 0;
  const n = text.length;
  while (i < n) {
    const c = text[i];
    if (c === "\\") {
      const next = text[i + 1];
      if (next === "%" || next === "\\") {
        run += next; // escape resolved to the literal char
        i += 2;
      } else {
        run += "\\"; // lone backslash stays a literal char
        i += 1;
      }
    } else if (c === "%") {
      const t = matchTokenAt(text, i + 1);
      if (t) {
        flush();
        segs.push({ type: "ref", id: t.id });
        i += 1 + t.length;
      } else {
        run += "%"; // bare/literal percent joins the text run
        i += 1;
      }
    } else {
      run += c;
      i += 1;
    }
  }
  flush();
  return segs;
}
