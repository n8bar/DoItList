import { strict as assert } from "node:assert";
import { test } from "node:test";

import { escapeHtml, failureMessage, recoveryScreen } from "./recovery.ts";

test("escapeHtml neutralises markup", () => {
  assert.equal(escapeHtml(`<img src="x" onerror='y'>&`), "&lt;img src=&quot;x&quot; onerror=&#39;y&#39;&gt;&amp;");
});

test("recoveryScreen carries the title, detail, and a Reload control", () => {
  const html = recoveryScreen("Couldn’t start", "Boom");
  assert.match(html, /Couldn’t start/);
  assert.match(html, /Boom/);
  assert.match(html, /id="boot-reload"/);
  assert.match(html, /Reload/);
});

test("recoveryScreen escapes an error message it is handed", () => {
  const html = recoveryScreen("Title", "<script>alert(1)</script>");
  assert.equal(html.includes("<script>"), false);
  assert.match(html, /&lt;script&gt;/);
});

test("failureMessage prefers a real message and always says something", () => {
  assert.equal(failureMessage(new Error("kaboom")), "kaboom");
  assert.equal(failureMessage("string failure"), "string failure");
  assert.match(failureMessage(null), /unexpected error/);
  assert.match(failureMessage(new Error("")), /unexpected error/);
});
