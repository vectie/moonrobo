import test from "node:test";
import assert from "node:assert/strict";
import { RAISED_LAST, raisedPair, raisedPhase } from "./raised-drums.js";

test("preview matches the raised, alternating drop, and exact return poses", () => {
  for (const [frame,pair] of [[0,[-10,-12]],[3000,[-90,-90]],[3500,[-60,-90]],
    [4300,[-90,-60]],[5100,[-60,-90]],[5900,[-90,-60]],[6300,[-90,-90]],[RAISED_LAST,[-10,-12]]]) {
    assert.deepEqual(raisedPair(frame,-10,-12),pair);
  }
  assert.match(raisedPhase(3500),/左肘/); assert.match(raisedPhase(4300),/右肘/);
});

test("all preview samples stay in travel and change smoothly between phases", () => {
  let prior=raisedPair(0,-10,-12);
  for (let i=1;i<=RAISED_LAST;i++) {
    const pair=raisedPair(i,-10,-12);
    pair.forEach((angle,side) => {
      assert.ok(angle>=-90 && angle<=-10);
      assert.ok(Math.abs(angle-prior[side])<=30*Math.PI/16*.02+1e-9);
    });
    prior=pair;
  }
});
