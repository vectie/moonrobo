import assert from "node:assert/strict";
import test from "node:test";
import {bodyReward,firstPersistent,frameErrors,gapShares,radToDeg} from "./orientation-math.js";
const id=[1,0,0,0], rootYaw=[Math.sqrt(.5),0,0,Math.sqrt(.5)];
const pose=q=>Array.from({length:14},()=>q);
const stream=(...poses)=>new Float32Array(poses.flat(2));
test("a common heading and opposite quaternion signs leave all aligned angles zero",()=>{
  const data=stream(pose(id),pose(rootYaw),pose(rootYaw.map(x=>-x)),pose(id));
  for(const e of frameErrors(data,0).flat())assert.ok(Math.abs(e)<1e-6);
});
test("one limb deviates in the reference and returns toward the source in physics",()=>{
  const ref=pose(id),actual=pose(id);
  ref[11]=[Math.cos(Math.PI/6),Math.sin(Math.PI/6),0,0];
  actual[11]=[Math.cos(Math.PI/12),Math.sin(Math.PI/12),0,0];
  const e=frameErrors(stream(pose(id),ref,actual,pose(id)),0);
  [60,30,30,0].forEach((deg,k)=>assert.ok(Math.abs(e[k][11]*radToDeg-deg)<1e-5));
  assert.ok(bodyReward(e[2])>bodyReward(e[0]));
  const g=gapShares(e[3],e[1],bodyReward(e[3]),bodyReward(e[1]));
  assert.equal(g.filter(v=>v!==0).length,1);
  assert.ok(Math.abs(g[11]-(bodyReward(e[3])-bodyReward(e[1])))<1e-15);
});
test("onsets count consecutive, strictly over-threshold frames including reset",()=>{
  assert.equal(firstPersistent([17,17,17,17,17],15),0);
  assert.equal(firstPersistent([16,16,15,16,16,16,16,16],15),3);
  assert.equal(firstPersistent([16,16,16,16],15),null);
});
