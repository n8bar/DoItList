/**
 * Roll-up progress + completion-cascade math — the ONE deliberate, sanctioned
 * client-side duplicate of `DoIt.Tasks.Progress` (see its moduledoc,
 * lib/doit/tasks/progress.ex) and of the "all children done" cascade rule
 * (`check_completed_ancestors` / `uncheck_done_ancestors` in lib/doit/tasks.ex).
 *
 * m03.02 item 3 ("Client-side instant prediction"): this file exists ONLY to
 * paint an instant, honest-best-guess number/done-state on a task's ANCESTOR
 * rows the moment the acting user edits their own leaf — never to persist
 * anything, never treated as the record. `computed_progress` in Postgres
 * (recomputed server-side, synchronously, in the same transaction as the
 * write — see m03.02 item 1) stays the single source of truth; the next real
 * server update (this write's own confirming render, or any later broadcast)
 * always wins if it's ever different.
 *
 * Pure, dependency-free, no DOM access, no imports. Gathering the right
 * input list (which leaves / which direct children, with the just-edited
 * value substituted in) is the CALLER's job — see the ancestor-prediction
 * helpers in app.js.
 *
 * Loaded two ways (matches assets/vendor/topbar.js's existing UMD pattern —
 * the only other file in this codebase with the same "plain browser script
 * AND esbuild-bundled import" requirement):
 *   - `assets/js/app.js` (esbuild bundle) does
 *     `import DoitRollup from "./rollup.js"` — a CommonJS-shaped default
 *     import, which esbuild's interop supports unconditionally (no static
 *     named-export detection needed).
 *   - `assets/js/rollup_test.html` loads it as a plain, non-module
 *     `<script src="rollup.js">` — no build step, no Node, works from a
 *     double-clicked file:// path (ES module `<script type="module">` +
 *     `file://` is blocked by CORS in every major browser, so this file
 *     deliberately avoids `import`/`export` keywords entirely).
 */
(function (global) {
  "use strict";

  /**
   * Averages a list of leaf-progress values (0-100 each) into a single
   * rolled-up integer, 0-100.
   *
   * Mirrors `DoIt.Tasks.Progress.average/1` exactly:
   *   - `[]` -> 0 (a branch with no children is treated as a leaf by the
   *     CALLER before it ever reaches here — see progress.ex's moduledoc —
   *     but this function matches `average([])` for the zero-leaf edge case
   *     on its own terms too).
   *   - round HALF UP to the nearest integer (`Decimal.round(0, :half_up)`).
   *     `Math.round` is round-half-away-from-zero for positive numbers,
   *     which is exactly half-up for this domain (every value here is a
   *     non-negative percentage) — verified against Decimal's behavior at
   *     the halfway points that actually arise from integer/integer
   *     division (e.g. sum=151,count=2 -> 75.5 -> 76 both ways; sum=1,
   *     count=2 -> 0.5 -> 1 both ways). No float-precision risk either: any
   *     exact .5 that can arise from dividing two integers is exactly
   *     representable in IEEE-754 (0.5 = 2^-1), so there's no epsilon drift
   *     at the boundary Decimal and Math.round would disagree on.
   *   - clamp to 0..100.
   *
   * `mode` ("leaf_average" | "single_level") is accepted for signature
   * parity with `DoIt.Tasks.Progress.compute/2` and so call sites read the
   * same way the Elixir does — but the averaging arithmetic itself is
   * IDENTICAL for both modes in progress.ex (both funnel into the same
   * `average/1`). The mode only changes what list the CALLER builds (every
   * descendant leaf for leaf_average; only direct children's own rolled-up
   * values for single_level) — see app.js's `predictAncestors`.
   */
  function computeRollup(leafProgressList, _mode) {
    if (!leafProgressList || leafProgressList.length === 0) return 0;

    var sum = 0;
    for (var i = 0; i < leafProgressList.length; i++) {
      sum += leafProgressList[i];
    }
    var rounded = Math.round(sum / leafProgressList.length);

    if (rounded < 0) return 0;
    if (rounded > 100) return 100;
    return rounded;
  }

  /**
   * Given a list of booleans (each direct child's done-state), returns
   * whether the parent should now be considered done.
   *
   * Mirrors the cascade check inlined in `check_completed_ancestors/2`
   * (lib/doit/tasks.ex): `siblings != [] and Enum.all?(siblings, &(&1.status
   * == "done"))` — an empty list is NOT "all done" (a parent with zero
   * children never auto-completes), matching that `siblings != []` guard.
   */
  function computeDoneCascade(childStatusList) {
    if (!childStatusList || childStatusList.length === 0) return false;

    for (var i = 0; i < childStatusList.length; i++) {
      if (!childStatusList[i]) return false;
    }
    return true;
  }

  var DoitRollup = {
    computeRollup: computeRollup,
    computeDoneCascade: computeDoneCascade,
  };

  if (typeof module === "object" && typeof module.exports === "object") {
    module.exports = DoitRollup;
  } else {
    global.DoitRollup = DoitRollup;
  }
}.call(this, this));
