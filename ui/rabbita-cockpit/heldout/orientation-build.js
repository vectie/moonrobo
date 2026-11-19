import {readFileSync} from "node:fs";
import {createHash} from "node:crypto";
import {summarizePoseStream} from "./orientation-math.js";

const base=new URL("../public/heldout/",import.meta.url);
const fileSha=p=>createHash("sha256").update(readFileSync(new URL(p,base))).digest("hex");
const json=p=>JSON.parse(readFileSync(new URL(p,base)));
function verified(path,sha) {
  const b=readFileSync(new URL(path,base));
  if(createHash("sha256").update(b).digest("hex")!==sha)throw Error("Orientation input digest mismatch: "+path);
  return new Float32Array(b.buffer.slice(b.byteOffset,b.byteOffset+b.byteLength));
}
function compute(){
  const geometry=json("orientation/manifest.json"), panel=json("tracks/manifest.json"), workflow=json("workflow/manifest.json"), tests=json("orientation/controls.json");
  if(![panel,tests,workflow].every(x=>x.panel_sha256===geometry.panel_sha256 && x.clips.length===40))throw Error("Orientation specimens differ");
  const sourceTests=json("orientation/source-controls.json");
  if(sourceTests.geometry_sha256!==fileSha("orientation/manifest.json") || sourceTests.controls_sha256!==fileSha("orientation/controls.json") ||
      sourceTests.scene_sha256!==panel.robots.e1.scene_sha256 || !(sourceTests.max_body_angle_discrepancy_rad < 1e-5) ||
      sourceTests.clips.length!==40 || geometry.clips.length!==40)throw Error("Source-target control provenance differs");
  const clips=geometry.clips.map((c,i)=>{
    const p=panel.clips[i],w=workflow.clips[i],t=tests.clips[i];
    if(c.id!==p.id||c.id!==w.id||c.id!==t.id||c.steps!==Math.min(p.g1.steps,p.e1.steps)||c.expected_steps!==p.expected_steps||
       c.e1_pose_sha256!==p.e1.sha256||c.g1_pose_sha256!==p.g1.sha256)throw Error("Orientation replay mismatch");
    const data=verified("orientation/"+i+".f32",c.sha256);
    const metrics=Object.fromEntries(["g1","e1"].map(r=>[r,verified("workflow/"+w[r].file,w[r].sha256)]));
    const summary=summarizePoseStream(data,c,metrics);
    if(Math.abs(summary.scores[3]-summary.scores[1]-(w.g1.shared_terms[1]-w.e1.shared_terms[1]))>1e-6)throw Error("Published gap differs");
    const source=sourceTests.clips[i];
    if(source.id!==p.id || source.common!==t.common || source.pose_sha256[3]!==p.e1.sha256 ||
       t.common!==Math.min(c.steps,...t.steps))throw Error("Physical control window differs");
    if(t.common===c.steps && Math.abs(source.source_scores[3]-summary.scores[2])>1e-7)throw Error("Independent MuJoCo score differs");
    return {...c,...summary,controls:{...t,sourceScores:source.source_scores}};
  });
  return {...geometry,clips,control_runs:tests.runs};
}
// Build-time only. Browser fetches one pose stream when its motion is selected.
export function orientationEvidence(){
  let cache;
  return {name:"paired-orientation-evidence",
    resolveId(id){if(id==="virtual:orientation-evidence")return "\0"+id;},
    load(id){if(id==="\0virtual:orientation-evidence")return "export default "+JSON.stringify(cache??=compute());},
  };
}
