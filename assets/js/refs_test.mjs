// Unit suite for the DOM-free %-notation core (assets/js/refs.js).
//
// Runs on Node's built-in runner — zero install, no bundler:
//
//   node --test assets/js/refs_test.mjs
//
// `test/assets/refs_js_test.exs` runs this same command so `mix test` stays the
// single gate (m03.04 item 6.2.2).
//
// The `resolve`/`labelOf` callbacks here stand in for the live DOM label map
// (app.js `resolveRefPath` / `refLabelOf`), which reads `[data-copy-index]` off
// every tree row. That map is the ONLY authority on which paths are real, so
// these tests pair each grammar case with a map that does or does not carry it.

import test from "node:test"
import assert from "node:assert/strict"

import { transformForSave, rehydrate, collectRefs, segments } from "./refs.js"

// One label per index style, exactly as `DoIt.Tasks.Index.label/2` formats them.
const LABELS = new Map([
  ["1.2", 12], // numerical
  ["I.A.2", 34], // outline: roman > alpha upper > numeric
  ["I.A.2.b.iv", 56], // outline, five levels (alpha lower, roman lower)
  ["III", 78], // roman
  ["B", 90], // alphabetical
  ["iv", 101] // lower roman
])

const resolve = (path) => (LABELS.has(path) ? LABELS.get(path) : null)
const labelOf = (id) => {
  for (const [label, known] of LABELS) if (known === id) return label
  return null
}

// --- 6.2.2: labels of every index style resolve --------------------------

test("numerical labels resolve", () => {
  assert.equal(transformForSave("see %1.2", resolve), "see %<12>")
})

test("outline labels resolve", () => {
  assert.equal(transformForSave("see %I.A.2", resolve), "see %<34>")
  assert.equal(transformForSave("see %I.A.2.b.iv", resolve), "see %<56>")
})

test("roman labels resolve", () => {
  assert.equal(transformForSave("see %III", resolve), "see %<78>")
  assert.equal(transformForSave("see %iv", resolve), "see %<101>")
})

test("alphabetical labels resolve", () => {
  assert.equal(transformForSave("see %B", resolve), "see %<90>")
})

test("several refs of mixed styles resolve in one string", () => {
  assert.equal(
    transformForSave("%1.2 blocks %I.A.2, not %III", resolve),
    "%<12> blocks %<34>, not %<78>"
  )
})

test("a ref at the end of a sentence keeps the period", () => {
  assert.equal(transformForSave("blocked by %1.2.", resolve), "blocked by %<12>.")
})

// --- 6.2.2: plain words after `%` stay literal ---------------------------

test("a mixed-case word after % is not a path", () => {
  assert.equal(transformForSave("%Important thing", resolve), "%Important thing")
  assert.deepEqual(collectRefs("%Important thing"), [])
})

test("a lowercase word after % matches the grammar but resolves to nothing", () => {
  // `plan` is a syntactically valid alphabetical path; the live map decides.
  assert.equal(transformForSave("%plan for later", resolve), "%plan for later")
})

test("an unmapped label stays literal", () => {
  assert.equal(transformForSave("%IV", resolve), "%IV")
  assert.equal(transformForSave("%TODO", resolve), "%TODO")
})

test("a path glued to letters or digits is not a path", () => {
  assert.equal(transformForSave("%I.A.2x", resolve), "%I.A.2x")
  assert.equal(transformForSave("%1st place", resolve), "%1st place")
  assert.equal(transformForSave("%B4 lunch", resolve), "%B4 lunch")
  assert.equal(transformForSave("%1.2_draft", resolve), "%1.2_draft")
})

test("a bare percent stays literal", () => {
  assert.equal(transformForSave("50% done", resolve), "50% done")
  assert.equal(transformForSave("ends with %", resolve), "ends with %")
})

// A path glued to trailing junk falls back to its longest MAPPED prefix, since
// the grammar may still end at the dot before the junk. Pinned, not endorsed:
// it is the pre-existing numerical behaviour, now reachable in every style.
test("trailing junk after a mapped prefix leaves the prefix a ref", () => {
  const withParent = (path) => (path === "I.A" ? 7 : resolve(path))
  assert.equal(transformForSave("%I.A.2x", withParent), "%<7>.2x")
})

// --- escapes and stored tokens: unchanged --------------------------------

test("an escaped percent is never a ref", () => {
  assert.equal(transformForSave("\\%1.2", resolve), "\\%1.2")
  assert.equal(transformForSave("\\%I.A.2", resolve), "\\%I.A.2")
  assert.deepEqual(collectRefs("\\%1.2"), [])
})

test("an escaped backslash is carried verbatim", () => {
  assert.equal(transformForSave("\\\\", resolve), "\\\\")
  assert.equal(transformForSave("C:\\path %1.2", resolve), "C:\\path %<12>")
})

test("a stored token passes through save verbatim", () => {
  assert.equal(transformForSave("see %<12>", resolve), "see %<12>")
})

test("stored tokens rehydrate to their current label", () => {
  assert.equal(rehydrate("see %<34>", labelOf), "see %I.A.2")
  assert.equal(rehydrate("see %<999>", labelOf), "see %?")
  assert.equal(rehydrate("\\%<34>", labelOf), "\\%<34>")
})

test("segments splits stored text into text and ref runs", () => {
  assert.deepEqual(segments("see %<12> now"), [
    { type: "text", value: "see " },
    { type: "ref", id: 12 },
    { type: "text", value: " now" }
  ])
  assert.deepEqual(segments("100\\% of %<90>"), [
    { type: "text", value: "100% of " },
    { type: "ref", id: 90 }
  ])
})

test("collectRefs reports each unescaped path with its offset", () => {
  assert.deepEqual(collectRefs("a %I.A.2 and %B"), [
    { path: "I.A.2", index: 2 },
    { path: "B", index: 13 }
  ])
})

// A long dotted run of same-class segments must still settle promptly: the
// matcher backtracks over prefixes, and a pasted outline can be deep.
test("a long unresolvable path does not hang the matcher", () => {
  const text = "%" + Array(40).fill("I").join(".") + "x"
  const started = Date.now()
  assert.equal(transformForSave(text, resolve), text)
  assert.ok(Date.now() - started < 1000, "matcher took too long")
})
