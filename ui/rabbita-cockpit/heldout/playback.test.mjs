import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { robots, validatePanel, decodeTrack, frameAt, fineTunedPanel } from "./playback.js";

const root = new URL("../public/heldout/", import.meta.url);
const bench = new URL("../testdata/heldout-benchmark/", import.meta.url);
const json = async (base, path) => JSON.parse(await readFile(new URL(path, base), "utf8"));
const hash = b => createHash("sha256").update(b).digest("hex");

test("fine-tuned E1 recordings reproduce the paired outcomes and preserve the G1 track", async () => {
  const prefix = "arm-ik/finetune/";
  const [original, scores, poses, evaluation] = await Promise.all(
    ["tracks/manifest.json", prefix + "result.json", prefix + "e1/poses.json", prefix + "final.json"].map(p => json(root, p))
  );
  const panel = fineTunedPanel(original, scores, poses);
  assert.equal(panel.robots.e1.actor_sha256, evaluation.actor_archive_sha256);
  for (const [i, clip] of panel.clips.entries()) {
    assert.equal(clip.g1, original.clips[i].g1);
    assert.equal(clip.e1.score, evaluation.per_clip[i].normalized_return);
    const bytes = await readFile(new URL(prefix + clip.e1.file, root));
    assert.equal(hash(bytes), clip.e1.sha256);
    const at = decodeTrack(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength), clip.e1, panel.robots.e1.joints.length);
    assert.deepEqual(at(clip.e1.steps + 1), at(clip.e1.steps));
  }
  assert.throws(() => fineTunedPanel(original, scores, {...poses, clips: poses.clips.toReversed()}));
});

test("all 80 physical tracks match the benchmark and freeze on the recorded final pose", async () => {
  const panel = validatePanel(await json(root, "tracks/manifest.json"));
  for (const robot of robots) {
    const report = await json(bench, robot + ".json");
    assert.equal(report.actor_archive_sha256, panel.robots[robot].actor_sha256);
    const scores = new Map(report.per_clip.map(c => [c.clip_id, c]));
    for (const clip of panel.clips) {
      const meta = clip[robot], ref = scores.get(clip.id);
      assert.equal(meta.steps, ref.executed_steps);
      assert.equal(meta.score, ref.normalized_return);
      assert.equal(meta.termination_frame, ref.termination_frame?.[0] ?? null);
      assert.equal(meta.completed, ref.completed_full_duration);
      const bytes = await readFile(new URL("tracks/" + meta.file, root));
      assert.equal(hash(bytes), meta.sha256);
      const pose = decodeTrack(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength), meta, panel.robots[robot].joints.length);
      assert.deepEqual(pose(meta.steps + 1), pose(meta.steps));
      assert.notDeepEqual(pose(0), pose(meta.steps));
      for (const n of [0, Math.floor(meta.steps / 2), meta.steps]) {
        assert.ok(Math.abs(Math.hypot(...pose(n).subarray(3, 7)) - 1) < 2e-6);
      }
    }
  }
  const clip = panel.clips.find(c => c.id === "karate/M_Move3");
  assert.deepEqual([frameAt(636, clip.g1), frameAt(636, clip.e1)], [636,635]);
  assert.deepEqual([clip.g1.steps, clip.e1.steps, clip.expected_steps], [1597,635,1597]);
});

test("all workflow time windows and reward components reproduce the frozen comparison", async () => {
  const panel = validatePanel(await json(root,"tracks/manifest.json"));
  const wf = await json(root,"workflow/manifest.json");
  assert.equal(wf.panel_sha256,panel.panel_sha256);
  assert.equal(wf.columns.length,11);
  const close = (x,y) => assert.ok(Math.abs(x-y)<1e-7, x+" vs "+y);
  for (const [i,c] of panel.clips.entries()) {
    const d=wf.clips[i], common=Math.min(c.g1.steps,c.e1.steps);
    assert.equal(d.id,c.id);
    for (const robot of robots) {
      const r=c[robot], metrics=d[robot];
      const bytes=await readFile(new URL("workflow/"+metrics.file,root));
      assert.equal(hash(bytes),metrics.sha256);
      assert.equal(bytes.length,r.steps*44);
      const terms=Array(8).fill(0);
      let shared=0,tail=0;
      for (let j=0;j<r.steps;j++) {
        const get=k=>bytes.readFloatLE(j*44+k*4);
        const reward=get(0);
        if(j<common) shared+=reward; else tail+=reward;
        const z=get(1), tilt=get(2);
        // Residuals are serialized to f32; all crossings in this panel are unambiguous.
        assert.equal(z>0.25 || tilt>0.8, !r.completed && j+1===r.steps);
        let sum=0;
        for(let k=0;k<8;k++){ sum+=get(k+3); if(j<common)terms[k]+=get(k+3); }
        close(sum,reward);
      }
      const full=c.expected_steps*0.1;
      close(shared/full,metrics.shared); close(tail/full,metrics.tail);
      close((shared+tail)/full,r.score);
      terms.forEach((v,k)=>close(v/full,metrics.shared_terms[k]));
    }
  }
});
