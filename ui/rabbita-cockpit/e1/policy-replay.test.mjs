import test from "node:test";
import assert from "node:assert/strict";
import { parsePolicyReplay, policyCurves } from "./policy-replay.js";

const names = Array.from({length:23}, (_,i) => `joint_${i}`);
names[16] = "l_arm_elbow_pitch_joint"; names[21] = "r_arm_elbow_pitch_joint";
const pose = () => [0,0,.85,0,0,0,1,...Array(23).fill(0)];
function fixture() {
  const frames = [0,20].map(at_ms => ({at_ms, phase:at_ms ? "policy" : "baseline", authority:at_ms ? .25 : 0,
    raw:pose(), applied:pose(), measured:pose()}));
  frames[1].raw[23] = -.8; frames[1].applied[23] = -.1;
  frames[1].raw[7] = .5;
  return {format:"moonrobo.e1-actor-policy-replay.v1", published:false, source_kind:"recorded-input",
    model_id:"a".repeat(64), names:[...names], step_ms:20, fixed_motor_records:22, maximum_authority:.25, frames};
}
test("inference replay distinguishes raw targets applied candidates and historical measurements", () => {
  const tape = parsePolicyReplay(fixture(), names);
  const curves = policyCurves(tape, 16);
  assert.equal(curves.length, 3);
  assert.ok(curves[0][1] < curves[1][1]);
  assert.equal(curves[2][1], 0);
  assert.equal(policyCurves(tape,0)[1][1], 0);
});
test("inference replay rejects false publication provenance changed legs and missing model ticks", () => {
  for (const corrupt of [t => t.published=true, t => t.source_kind="live", t => t.model_id="unknown",
    t => t.frames[1].applied[7]=.001, t => t.frames[1].at_ms=40,
    t => t.frames[1].authority=.5, t => t.frames[0].authority=.1]) {
    const tape=fixture(); corrupt(tape);
    assert.throws(() => parsePolicyReplay(tape,names));
  }
});
