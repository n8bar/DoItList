// The client above the socket does not know which transport it is on
// (UX_GUARDRAILS §6.9; m04.03 6.7).
//
// Phoenix falls back from WebSocket to long-polling on its own; the
// `DoItWeb.Endpoint` offers both on `/socket`. For that fallback to change
// nothing about the §6 guarantees, everything above the transport — the
// connection, the sessions, the adapter, the screens — must be driven only
// through the `LiveTransport` interface. This test reads the client tree and
// checks that `phoenix_transport.ts` is the one file that names Phoenix or a
// WebSocket in code (comments do not count).

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const ROOT = new URL("..", import.meta.url).pathname.replace(/\/$/, "");
const ALLOWED = "live/phoenix_transport.ts";

function sources(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) sources(path, out);
    else if (/\.(ts|tsx)$/.test(name) && !/\.test\.tsx?$/.test(name) && name !== "globals.d.ts") out.push(path);
  }
  return out;
}

/** The file with its comments taken out, so a mention in prose is not a use. */
const code = (path: string): string =>
  readFileSync(path, "utf8")
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/(^|[^:"'`])\/\/.*$/gm, "$1");

describe("only the transport knows the transport (§6.9)", () => {
  const files = sources(ROOT).map((path) => relative(ROOT, path));

  it("names Phoenix and WebSocket in exactly one file", () => {
    const offenders = files.filter((file) => file !== ALLOWED && /\bWebSocket\b|from "phoenix"|\bnew Socket\(|\blongpoll\b/i.test(code(join(ROOT, file))));
    assert.deepEqual(offenders, [], "these files reach past the LiveTransport interface");
    assert.ok(files.includes(ALLOWED));
    assert.match(code(join(ROOT, ALLOWED)), /from "phoenix"/);
  });

  it("the connection is built over the interface, never over the socket", () => {
    const connection = code(join(ROOT, "live/connection.ts"));
    assert.match(connection, /import type \{[^}]*\bLiveTransport\b[^}]*\} from "\.\/transport\.ts"/);
    assert.doesNotMatch(connection, /phoenix_transport/);
  });
});
