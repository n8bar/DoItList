import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { CONTROL_BASE, actionClass, controlClass } from "./button_styles.ts";

const classes = (options?: Parameters<typeof controlClass>[0]) =>
  new Set(controlClass(options).split(/\s+/));

describe("nav control states", () => {
  it("always draws a boundary, a focus ring and a touch-sized target", () => {
    for (const options of [{}, { current: true }, { open: true }, { disabled: true }]) {
      const set = classes(options);
      assert.ok(set.has("border"), "no visible boundary");
      assert.ok(set.has("min-h-11"), "under the 44px touch target");
      assert.ok(set.has("sm:min-h-9"), "no denser pointer size");
      assert.ok(
        [...set].some((c) => c.startsWith("focus-visible:ring-2")),
        "no focus ring",
      );
    }
  });

  it("guards its motion", () => {
    assert.ok(classes().has("motion-reduce:transition-none"));
  });

  it("styles both themes in every state", () => {
    for (const options of [{}, { current: true }, { open: true }, { disabled: true }]) {
      const dark = [...classes(options)].filter((c) => c.startsWith("dark:"));
      assert.ok(dark.length > 0, `no dark: classes for ${JSON.stringify(options)}`);
    }
  });

  it("tells the four states apart", () => {
    const seen = new Set(
      [{}, { current: true }, { open: true }, { disabled: true }].map((options) =>
        controlClass(options),
      ),
    );
    assert.equal(seen.size, 4, "two states look the same");
  });

  it("gives default, current and open a pressed state", () => {
    for (const options of [{}, { current: true }, { open: true }]) {
      assert.ok(
        [...classes(options)].some((c) => c.startsWith("active:")),
        `no pressed state for ${JSON.stringify(options)}`,
      );
    }
  });

  it("makes a disabled control unclickable and lower contrast", () => {
    const set = classes({ disabled: true });
    assert.ok(set.has("pointer-events-none"));
    assert.ok(set.has("cursor-not-allowed"));
    assert.ok(set.has("text-zinc-400"));
    assert.ok(!set.has("hover:bg-zinc-100"), "a disabled control still reacts to hover");
  });

  it("ranks disabled over current over open", () => {
    assert.equal(
      controlClass({ disabled: true, current: true, open: true }),
      controlClass({ disabled: true }),
    );
    assert.equal(controlClass({ current: true, open: true }), controlClass({ current: true }));
  });

  it("has one shape at a time", () => {
    assert.ok(classes().has("justify-center"));
    assert.ok(classes({ block: true }).has("justify-start"));
    assert.ok(!classes({ block: true }).has("justify-center"));
    assert.ok(classes({ stack: true }).has("flex-col"));
    assert.ok(!classes({ stack: true }).has("justify-start"));
  });

  it("keeps the shared base in every variant", () => {
    for (const part of CONTROL_BASE.split(/\s+/)) {
      assert.ok(classes({ current: true }).has(part), `base class ${part} went missing`);
    }
  });
});

describe("action buttons (item 4.2)", () => {
  const action = (options?: Parameters<typeof actionClass>[0]) =>
    new Set(actionClass(options).split(/\s+/));

  it("keeps the shared base — same size, same ring, same touch target", () => {
    for (const variant of ["default", "primary", "danger"] as const) {
      const set = action({ variant });
      for (const part of CONTROL_BASE.split(/\s+/)) {
        assert.ok(set.has(part), `${variant} lost the base class ${part}`);
      }
    }
  });

  it("tells the three variants apart", () => {
    assert.notEqual(actionClass({ variant: "primary" }), actionClass({ variant: "danger" }));
    assert.notEqual(actionClass({ variant: "primary" }), actionClass());
  });

  it("carries a dark-theme rule for every variant", () => {
    for (const variant of ["default", "primary", "danger"] as const) {
      assert.ok(
        [...action({ variant })].some((c) => c.startsWith("dark:")),
        `${variant} has no dark-theme styling`,
      );
    }
  });

  it("makes a busy action unclickable without letting it read as available", () => {
    const set = action({ variant: "primary", disabled: true });
    assert.ok(set.has("pointer-events-none"));
    assert.ok(!set.has("bg-emerald-600"), "a disabled primary still looks like the CTA");
  });
});
