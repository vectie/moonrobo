// Numerical integration test of the same simulator and networks used by the page.
// Usage: node g1/panel-check.mjs BUNDLE_ROOT > paired-browser-panel.json
import fs from "node:fs/promises";
import path from "node:path";
import assert from "node:assert/strict";
import mujoco from "@mujoco/mujoco";
import { modelFromBytes, frame, digest } from "./model.js";
import { Simulation } from "./simulation.js";
const root = process.argv[2];
if (!root) throw Error("Provide the local G1 bundle root");
const read = async (rel) => fs.readFile(path.join(root, rel));
const json = async (rel) => JSON.parse(await read(rel));
const panel = JSON.parse(
  await fs.readFile(new URL("../public/g1/panel.json", import.meta.url)),
);
const kernel = await WebAssembly.compile(
  await fs.readFile(new URL("./dense.wasm", import.meta.url)),
);
const packs = {};
for (const tag of ["early", "final"]) {
  const m = await json("private/" + tag + "/model.json"),
    weights = await read("private/" + tag + "/weights.f32");
  packs[tag] = await modelFromBytes(m, Uint8Array.from(weights).buffer, kernel);
}
const mj = await mujoco(),
  xml = await read("source/g1/scene.xml"),
  vfs = new mj.MjVFS();
assert.equal(mj.mj_versionString(), "3.15.0");
assert.equal(await digest(xml), packs.final.meta.sceneSha256);
for (const name of new Set(
  Array.from(xml.toString().matchAll(/file="(meshes\/[^"]+)"/g), (m) => m[1]),
))
  vfs.addBuffer(name, new Uint8Array(await read("source/g1/" + name)));
const m = mj.MjModel.from_xml_string(xml.toString(), vfs);
vfs.delete();
const sim = new Simulation(mj, m, packs.final, packs.final);
sim.prediction = false;
const mapping = await json("source/panel-sources.json"),
  rows = [];
assert.equal(mapping.length, panel.per_clip.length);
try {
  for (const [i, metric] of panel.per_clip.entries()) {
    const { key, i: idx } = mapping[i],
      file = "source/clips/" + key.slice(0, 2) + "/" + key + ".f64";
    assert.equal(idx, metric.index);
    const bytes = await read(file);
    assert.equal(
      await digest(bytes),
      (await json(file + ".json")).state_sha256,
    );
    const f = new Float64Array(Uint8Array.from(bytes).buffer),
      clip = Array.from({ length: f.length / 76 }, (_, j) =>
        frame(f.subarray(j * 76, (j + 1) * 76)),
      );
    assert.equal(clip.length - 1, metric.expected_steps);
    const row = {
      index: idx,
      name: metric.clip,
      expected_steps: metric.expected_steps,
    };
    for (const tag of ["early", "final"]) {
      sim.policy = packs[tag];
      sim.reset(clip);
      while (!sim.end) sim.step();
      row[tag] = {
        browser_steps: sim.i,
        browser_failed: sim.end !== "Motion complete",
        apic_steps: metric[tag + "_steps"],
        apic_failed: metric[tag + "_failed"],
      };
    }
    rows.push(row);
    console.error(
      i +
        1 +
        "/40 " +
        row.name +
        " " +
        row.final.browser_steps +
        "/" +
        row.expected_steps,
    );
  }
} finally {
  sim.dispose();
}
const summary = Object.fromEntries(
  ["early", "final"].map((tag) => [
    tag,
    {
      browser_completed: rows.filter((r) => !r[tag].browser_failed).length,
      apic_completed: rows.filter((r) => !r[tag].apic_failed).length,
      matching_outcomes: rows.filter(
        (r) => r[tag].browser_failed === r[tag].apic_failed,
      ).length,
    },
  ]),
);
console.log(
  JSON.stringify(
    {
      format: "moonrobo.browser-g1-physics-check.v1",
      engine: mj.mj_versionString(),
      scene_sha256: packs.final.meta.sceneSha256,
      actor_source: packs.final.meta.sourceFiles["policy.pt"],
      friction: 1,
      action_noise: 0,
      summary,
      per_clip: rows,
    },
    null,
    2,
  ),
);
