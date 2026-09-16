import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { readFileSync } from "node:fs";

import { avatarBackground, avatarForeground, initials } from "./avatar_model.ts";

describe("initials (mirrors DoItWeb.CoreComponents.initials/1)", () => {
  it("takes the first and last name's first letters", () => {
    assert.equal(initials({ name: "Dana Scully", username: "dana" }), "DS");
  });

  it("uses the one word when there is only one", () => {
    assert.equal(initials({ name: "Prince", username: "prince" }), "P");
  });

  it("ignores a generational suffix", () => {
    assert.equal(initials({ name: "Alvin Cubbins III", username: "alvin" }), "AC");
    assert.equal(initials({ name: "Doris Fitzgerald Jr.", username: "doris" }), "DF");
  });

  it("falls back to the username when there is no name", () => {
    // Two letters, exactly as `initials_from_username/1` slices them.
    assert.equal(initials({ name: null, username: "dana" }), "DA");
    assert.equal(initials({ name: "   ", username: "dana" }), "DA");
  });

  it("never comes back empty", () => {
    assert.ok(initials({ name: null, username: "" }).length > 0);
  });
});

describe("the colour a user is drawn in", () => {
  it("is a gradient derived from the id, the same one the server derives", () => {
    // DoItWeb.CoreComponents.avatar_bg/1 for id 1:
    // rem(137, 360) = 137deg, bgs[1] = #0284c7, grads[1] = #9333ea
    assert.equal(avatarBackground(1), "linear-gradient(137deg, #0284c7, #9333ea)");
    assert.equal(avatarForeground(1), "#bae6fd");
  });

  it("is stable for a user and different between neighbours", () => {
    assert.equal(avatarBackground(42), avatarBackground(42));
    assert.notEqual(avatarBackground(42), avatarBackground(43));
  });

  it("uses the same palettes the server does, value for value", () => {
    const source = readFileSync(
      new URL("../../../../lib/doit_web/components/core_components.ex", import.meta.url),
      "utf8",
    );
    const client = readFileSync(new URL("./avatar_model.ts", import.meta.url), "utf8");
    for (const match of source.matchAll(/@avatar_\w+ ~w\(([^)]+)\)/g)) {
      for (const hex of (match[1] ?? "").split(/\s+/).filter((part) => part !== "")) {
        assert.ok(client.includes(hex), `${hex} is in the server's palette but not the client's`);
      }
    }
  });
});
