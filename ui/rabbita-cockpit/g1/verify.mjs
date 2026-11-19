// Runs against private native fixtures created by g1_browser_export.
import fs from "node:fs/promises";
import path from "node:path";
import assert from "node:assert/strict";
import {
  modelFromBytes,
  observation,
  goal,
  frame,
  worldInput,
  integrate,
  flatten,
} from "./model.js";
const root = process.argv[2];
if (!root) throw Error("Usage: node g1/verify.mjs LOCAL_BUNDLE_ROOT");
const json = async (p) =>
  JSON.parse(await fs.readFile(path.join(root, p), "utf8"));
const bytes = async (p) => Uint8Array.from(await fs.readFile(p)).buffer;
const kernel = await WebAssembly.compile(
  await bytes(new URL("./dense.wasm", import.meta.url)),
);
const [{ key }] = await json("source/panel-sources.json"),
  ref = new Float64Array(
    await bytes(path.join(root, "source/clips", key.slice(0, 2), key + ".f64")),
  );
const clip = Array.from({ length: ref.length / 76 }, (_, i) =>
  frame(ref.subarray(i * 76, (i + 1) * 76)),
);
function error(a, b) {
  assert.equal(a.length, b.length);
  return Math.max(...a.map((x, j) => Math.abs(x - b[j])));
}
for (const tag of ["final", "early"]) {
  const meta = await json("private/" + tag + "/model.json"),
    policy = await modelFromBytes(
      meta,
      await bytes(path.join(root, "private", tag, "weights.f32")),
      kernel,
    );
  const fixtures = await json("private/" + tag + "/native-fixtures.json");
  const max = {
    history: 0,
    goal: 0,
    action: 0,
    worldInput: 0,
    delta: 0,
    nextState: 0,
  };
  for (const row of fixtures) {
    const t = row.frame,
      h = Array.from({ length: 10 }, (_, i) => {
        const s = clip[Math.max(0, t - 9 + i)];
        return observation(s, Array(29).fill(0), s, meta.contract.default_q);
      }),
      g = goal(clip, t);
    max.history = Math.max(max.history, error(h.flat(), row.history.flat()));
    max.goal = Math.max(max.goal, error(g, row.goal));
    max.action = Math.max(max.action, error(policy.action(h, g), row.action));
    if (row.delta) {
      const input = worldInput(clip[t], row.action, 1),
        d = policy.delta(input);
      max.worldInput = Math.max(max.worldInput, error(input, row.worldInput));
      max.delta = Math.max(max.delta, error(d, row.delta));
      max.nextState = Math.max(
        max.nextState,
        error(flatten(integrate(clip[t], d)), row.nextState),
      );
    }
  }
  console.log(
    JSON.stringify({
      iteration: meta.iteration,
      fixtures: fixtures.length,
      max_absolute_differences: max,
    }),
  );
  assert.ok(
    max.history < 1e-7 && max.goal < 1e-7 && max.worldInput < 1e-4,
    "observation, preview or dynamics preprocessing mismatch",
  );
  assert.ok(
    max.action <= 0.04 && max.delta <= 0.05 && max.nextState <= 0.05,
    "browser BF16 forward deviated from native",
  );
}
