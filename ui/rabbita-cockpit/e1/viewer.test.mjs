import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import { createHash } from "node:crypto";
import { decodeMesh } from "./viewer.js";

test("browser mesh decoder rejects a truncated or out-of-range triangle", () => {
  const buffer = new ArrayBuffer(56), data = new DataView(buffer);
  data.setUint32(0, 3, true); data.setUint32(4, 3, true);
  new Float32Array(buffer, 8, 9).set([0, 0, 0, 1, 0, 0, 0, 1, 0]);
  new Uint32Array(buffer, 44, 3).set([0, 1, 2]);
  assert.equal(decodeMesh(buffer).getAttribute("position").count, 3);
  assert.throws(() => decodeMesh(buffer.slice(0, -4)));
  data.setUint32(52, 3, true);
  assert.throws(() => decodeMesh(buffer));
});
test("every shipped mesh and motion agrees with its Spark export digest and layout", async () => {
  const base = new URL("../public/e1/assets/", import.meta.url);
  const manifest = JSON.parse(await fs.readFile(new URL("manifest.json", base), "utf8"));
  assert.equal(manifest.robot.joints.length, 23);
  assert.equal(new Set(manifest.robot.joints).size, 23);
  const sha = (bytes) => createHash("sha256").update(bytes).digest("hex");
  assert.equal(sha(await fs.readFile(new URL("scene.xml", base))), manifest.scene_sha256);
  for (const item of Object.values(manifest.meshes)) {
    const bytes = await fs.readFile(new URL(item.file, base));
    assert.equal(sha(bytes), item.sha256);
    const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
    const geometry = decodeMesh(buffer);
    assert.equal(geometry.index.count / 3, item.triangles);
    geometry.dispose();
  }
  const panel = JSON.parse(await fs.readFile(new URL("panel-7000/manifest.json", base), "utf8"));
  assert.equal(panel.actor_sha256, "1fb12d353b0187efed1d9a2984c8a7790a5277b91e29f339f112571a44ff5a60");
  assert.deepEqual(panel.clips.map(clip => [clip.id, clip.frames]), [["7k-turn", 576], ["7k-stoop", 744], ["7k-lift", 574]]);
  const corrected = JSON.parse(await fs.readFile(new URL("panel-7000-anatomical/manifest.json", base), "utf8"));
  assert.equal(corrected.actor_sha256, panel.actor_sha256);
  assert.equal(corrected.source_checkpoint_sha256, panel.source_checkpoint_sha256);
  assert.equal(corrected.clips.length, 4);
  for (const clip of corrected.clips) {
    assert.match(clip.reference_sha256, /^[a-f0-9]{64}$/);
    assert.equal(clip.frames <= clip.expected_steps + 1, true);
    assert.equal(clip.frames === clip.expected_steps + 1, clip.completed);
  }
  const retrained = [];
  for (const [iteration, report] of [[7000, "comparison"], [14000, "final"]]) {
    const index = JSON.parse(await fs.readFile(new URL(`retrained-${iteration}/manifest.json`, base), "utf8"));
    const evaluation = JSON.parse(await fs.readFile(new URL(`../retrain/${report}.json`, base), "utf8"));
    assert.equal(index.actor_sha256, evaluation.actor_archive_sha256);
    assert.equal(index.source_checkpoint_sha256, evaluation.source_checkpoint_sha256);
    assert.equal(index.clips.length, 40);
    assert.equal(new Set(index.clips.map(c => c.clip_id)).size, 40);
    for (const [i, clip] of index.clips.entries()) {
      const measurement = evaluation.per_clip[i];
      assert.equal(clip.panel_index, i);
      assert.equal(clip.checkpoint, iteration);
      assert.equal(clip.clip_id, measurement.clip_id);
      assert.equal(clip.completed, measurement.completed_full_duration);
      assert.equal(clip.frames, measurement.executed_steps + 1);
      assert.equal(clip.expected_steps, measurement.expected_steps);
      assert.equal(clip.normalized_return, measurement.normalized_return);
    }
    retrained.push(...index.clips);
  }
  assert.equal(new Set(retrained.map(c => c.id)).size, 80);
  for (const clip of [...manifest.clips, ...panel.clips, ...corrected.clips, ...retrained]) {
    assert.equal(clip.width, 7 + manifest.robot.joints.length);
    assert.equal(clip.fps, 50);
    const bytes = await fs.readFile(new URL(clip.file, base));
    assert.equal(sha(bytes), clip.sha256);
    assert.equal(bytes.length, clip.frames * clip.width * 4);
    const values = new Float32Array(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
    assert.ok(values.every(Number.isFinite));
    for (let frame = 0; frame < clip.frames; frame++) {
      const i = frame * clip.width;
      assert.ok(Math.abs(Math.hypot(...values.subarray(i + 3, i + 7)) - 1) < 1e-5);
    }
  }
  assert.deepEqual(manifest.clips.map((clip) => clip.split), ["train", "train", "validation", "validation"]);
});
