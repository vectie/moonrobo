import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {frameErrors,radToDeg} from "./orientation-math.js";
import {summarize,modes} from "./arm-ik-stats.js";
import {decodeTrack,guardedPanel} from "./playback.js";
import {createHash} from "node:crypto";
const json=p=>JSON.parse(readFileSync(new URL("../public/heldout/"+p,import.meta.url)));
test("frozen 14k IK trials reconcile to the published 40 pairs and common windows",()=>{
  const report=json("arm-ik/results.json"),panel=json("tracks/manifest.json");
  assert.equal(report.panel_sha256,panel.panel_sha256);
  assert.equal(report.clips.length,40);
  for(const [i,c] of report.clips.entries()){
    const p=panel.clips[i],v=c.variants;
    assert.equal(c.id,p.id);
    assert.deepEqual(v.map(x=>x.mode),modes);
    assert.equal(v[0].physical_sha256,p.e1.sha256);
    assert.equal(v[0].normalized_return,p.e1.score);
    assert.equal(c.shared_steps,Math.min(p.g1.steps,...v.map(x=>x.steps)));
    assert.deepEqual(v.at(-1).reference_feet,v[0].reference_feet);
    const bytes=readFileSync(new URL("../public/heldout/orientation/"+i+".f32",import.meta.url));
    const raw=new Float32Array(bytes.buffer,bytes.byteOffset,bytes.byteLength/4);
    const sum=[0,0,0], e0=frameErrors(raw,0)[0];
    for(const [k,b] of [9,12].entries())assert.ok(Math.abs(e0[b]*radToDeg-v[0].elbow_zero_deg[k])<1e-4);
    for(let f=1;f<=c.shared_steps;f++){
      const channels=frameErrors(raw,f);
      for(let k=0;k<3;k++)sum[k]+=channels[k][11]**2/c.shared_steps;
    }
    sum.forEach((x,k)=>assert.ok(Math.abs(x-v[0].right_shoulder_mse_rad2[k])<1e-6));
    for(const r of v){
      assert.equal(r.physical_feet.samples,v[0].physical_feet.samples);
      for(const f of [r.reference_feet,r.physical_feet,r.whole_physical_feet]){
        assert.ok(f.touching<=f.near && f.near+f.lifted<=f.samples && f.slip_samples<=f.near);
      }
      assert.ok(r.right_shoulder_mse_rad2.every(x=>x>=0 && x<=Math.PI**2));
      assert.ok(r.steps>0 && r.steps<=c.expected_steps);
      if(r.completed)assert.equal(r.steps,c.expected_steps);
    }
  }
  for(const bucket of ["physical_feet","whole_physical_feet","reference_feet"]){
    const stats=summarize(report.clips,bucket);
    assert.ok(stats.every(s=>s.feet.speed>=0 && s.feet.samples>0 && s.angles.length===3));
  }
});

test("screened arm correction repairs the measured pair and retains the locked control elsewhere",()=>{
  const report=json("arm-ik/results.json");
  const replay=guardedPanel(json("tracks/manifest.json"),report);
  const refs=json("arm-ik/arms-guarded/references.json");
  const baseline=json("arm-ik/original/references.json");
  const observed=[];
  for(const [i,c] of report.clips.entries()){
    const original=c.variants[0],locked=c.variants[4],checked=c.variants[5];
    const meta=refs.clips[i],repair=meta.arm_repair;
    const track=readFileSync(new URL("../public/heldout/arm-ik/arms-guarded/"+replay.clips[i].e1.file,import.meta.url));
    assert.equal(createHash("sha256").update(track).digest("hex"),checked.physical_sha256);
    assert.equal(decodeTrack(track.buffer.slice(track.byteOffset,track.byteOffset+track.byteLength),replay.clips[i].e1,23)(checked.steps).length,30);
    assert.ok(checked.reasons.every(r=>original.reasons.includes(r)));
    assert.deepEqual(checked.reference_feet,original.reference_feet);
    if(repair==null){
      assert.equal(checked.reference_sha256,locked.reference_sha256);
      assert.equal(checked.physical_sha256,locked.physical_sha256);
      assert.equal(checked.normalized_return,locked.normalized_return);
      continue;
    }
    observed.push(c.id);
    assert.ok(repair.fraction>=0&&repair.fraction<1);
    assert.ok(meta.screen.maximum_self_penetration_m<=baseline.clips[i].screen.maximum_self_penetration_m+1e-9);
    const traces=c.pair_contact_traces;
    assert.deepEqual(traces.map(v=>v.mode),["original","arms-only","arms-guarded"]);
    for(const t of traces){
      assert.equal(t.reference_m.length,c.expected_steps+1);
      assert.equal(t.recorded_pose_m.length,c.variants[modes.indexOf(t.mode)].steps+1);
    }
    const former=traces[1],fixed=traces[2],frame=former.peak_frame_before_repair;
    assert.ok(Math.abs(former.reference_m[frame]-repair.initial_peak_m)<1e-8);
    assert.ok(fixed.reference_m[frame]<former.reference_m[frame]);
    assert.ok(Math.max(...fixed.reference_m)<=Math.max(...traces[0].reference_m)+1e-9);
    assert.ok(repair.attempts.some(a=>a.peak_m<=repair.baseline_peak_m+1e-9 && a.pair_excess_m>1e-9));
  }
  assert.deepEqual(observed,["dance/J_ShortDance14_Disco"]);
});
