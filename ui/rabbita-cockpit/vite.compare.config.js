// Standalone public replay player. Assets come from the two mesh inventories
// and the held-out panel, so neither the local cockpit nor model archives ship.
import { defineConfig } from "vite";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";

import { orientationEvidence } from "./heldout/orientation-build.js";

const publicDir = new URL("./public/", import.meta.url);
const read = path => readFileSync(new URL(path, publicDir));
const manifest = path => JSON.parse(read(path));
const sha = data => createHash("sha256").update(data).digest("hex");

export default defineConfig({
  base: "/robo/",
  publicDir: false,
  build: { rollupOptions: { input: ["compare.html", "workflow.html", "orientation.html", "arm-ik.html"] } },
  plugins: [orientationEvidence(), {
    name: "public-compare",
    transformIndexHtml: {
      order: "pre",
      handler(html) {
        return html.replaceAll('href="./compare.html"', 'href="./"').replace('class="brand" href="./g1.html"', 'class="brand" href="./"')
          .replace('href="./g1.html">G1', 'href="#g1-title">G1')
          .replace('href="./e1.html">E1', 'href="#e1-title">E1');
      },
    },
    generateBundle: {
      order: "post",
      handler(_, bundle) {
        const page = bundle["compare.html"];
        if (!page) this.error("Missing comparison entry page");
        delete bundle["compare.html"];
        page.fileName = "index.html";
        bundle[page.fileName] = page;
        const emit = (path, data) => this.emitFile({ type: "asset", fileName: path, source: data });
        const copy = (path, digest) => {
          const data = read(path);
          if (digest && sha(data) !== digest) this.error("Digest mismatch: " + path);
          emit(path, data);
        };
        const panel = manifest("heldout/tracks/manifest.json");
        copy("heldout/tracks/manifest.json");
        if (panel.clips.length !== 40) this.error("Expected 40 motion pairs");
        const workflow = manifest("heldout/workflow/manifest.json");
        if (workflow.panel_sha256 !== panel.panel_sha256 || workflow.clips.length !== panel.clips.length) {
          this.error("Workflow and replay panels differ");
        }
        copy("heldout/workflow/manifest.json");
        const orientation = manifest("heldout/orientation/manifest.json");
        copy("heldout/orientation/manifest.json");
        copy("heldout/orientation/controls.json");
        copy("heldout/orientation/source-controls.json");
        const armStudy=manifest("heldout/arm-ik/results.json");
        if(armStudy.panel_sha256!==panel.panel_sha256 || armStudy.clips.length!==40 ||
          armStudy.source_orientation_manifest_sha256!==sha(read("heldout/orientation/manifest.json")) ||
          armStudy.clips.some((c,i)=>c.id!==panel.clips[i].id || c.expected_steps!==panel.clips[i].expected_steps ||
            c.variants[0].physical_sha256!==panel.clips[i].e1.sha256 || c.variants[0].normalized_return!==panel.clips[i].e1.score))this.error("Arm retargeting study differs from the frozen panel");
        copy("heldout/arm-ik/results.json");
        const pairAudit=manifest("heldout/arm-ik/pair-audit.json");
        const audited=armStudy.clips.find(c=>c.id===pairAudit.motion);
        if(!audited?.pair_contact_traces?.length || pairAudit.panel_sha256!==panel.panel_sha256 ||
            pairAudit.scene_sha256!==panel.robots.e1.scene_sha256)this.error("Independent contact audit uses a different panel or scene");
        for(const t of audited.pair_contact_traces){
          const other=pairAudit.checks[t.mode],v=audited.variants.find(v=>v.mode===t.mode);
          if(!other || v.reference_sha256!==other.reference_sha256 || v.physical_sha256!==other.recorded_pose_sha256 ||
              Math.abs(other.reference.frame_499_m-t.reference_m[499])>1e-7 ||
              Math.abs(other.reference.peak_m-Math.max(...t.reference_m))>1e-7 ||
              Math.abs(other.recorded_pose.peak_m-Math.max(...t.recorded_pose_m))>1e-7)this.error("Independent contact audit disagrees with "+t.mode);
        }
        copy("heldout/arm-ik/pair-audit.json");
        const fineDir = "heldout/arm-ik/finetune/";
        const scores = manifest(fineDir + "result.json"), tracking = manifest(fineDir + "tracking.json");
        const poses = manifest(fineDir + "e1/poses.json"), evaluation = manifest(fineDir + "final.json");
        if (scores.actor_sha256.baseline !== armStudy.actor_sha256 || scores.actor_sha256.candidate !== evaluation.actor_archive_sha256 ||
            tracking.panel_sha256 !== panel.panel_sha256 || tracking.actor_sha256[1] !== scores.actor_sha256.candidate ||
            tracking.actor_sha256[0] !== scores.actor_sha256.baseline || scores.development_motions.length !== 40 ||
            scores.fresh_motions.length !== 21 || poses.clips.length !== 40 ||
            JSON.stringify(poses.joints) !== JSON.stringify(panel.robots.e1.joints)) this.error("Fine-tuning evaluation identities differ");
        for (const [i, item] of scores.development_motions.entries()) {
          const pose = poses.clips[i], roll = evaluation.per_clip[i];
          const old = armStudy.clips[i].variants.find(v => v.mode === "arms-guarded");
          if (item.motion !== panel.clips[i].id || item.motion !== roll.clip_id || item.motion !== pose.id ||
              item.baseline_return !== old.normalized_return || item.reference_sha256 !== old.reference_sha256 ||
              item.candidate_return !== roll.normalized_return || item.candidate_steps !== roll.executed_steps ||
              pose.frames !== roll.executed_steps + 1 || pose.file !== i + ".f32") this.error("Fine-tuning rollout differs: " + item.motion);
          copy(fineDir + "e1/" + pose.file, pose.sha256);
        }
        for (const name of ["result.json","tracking.json","final.json","e1/poses.json"]) copy(fineDir + name);
        for(const run of armStudy.runs){
          if(!["original","shoulders","elbows","both","arms-only","arms-guarded"].includes(run.mode))this.error("Unknown IK study variant");
          copy("heldout/arm-ik/"+run.mode+"/references.json",run.references_sha256);
          copy("heldout/arm-ik/"+run.mode+"/final.json",run.report_sha256);
        }
        for (const [i, clip] of panel.clips.entries()) {
          const guarded=armStudy.clips[i].variants.find(v=>v.mode==="arms-guarded");
          if(!guarded)this.error("Missing geometry-checked E1 pose track");
          copy("heldout/arm-ik/arms-guarded/e1/"+i+".f32", guarded.physical_sha256);
          copy("heldout/orientation/" + i + ".f32", orientation.clips[i].sha256);
          if (workflow.clips[i].id !== clip.id) this.error("Workflow clip mismatch");
          for (const robot of ["g1", "e1"]) {
            const { file, sha256 } = workflow.clips[i][robot];
            copy("heldout/workflow/" + file, sha256);
          }
          for (const key of ["g1", "e1"]) {
            const track = clip[key];
            copy("heldout/tracks/" + track.file, track.sha256);
          }
        }
        for (const [key, dir, license] of [
          ["g1", "heldout/g1-model/", "UNITREE-LICENSE.txt"],
          ["e1", "e1/assets/", "NOETIX-LICENSE.txt"],
        ]) {
          const model = manifest(dir + "manifest.json");
          if (model.scene_sha256 !== panel.robots[key].scene_sha256) this.error("Scene mismatch: " + key);
          const { format, scene_sha256, meshes } = model;
          const info = { format, scene_sha256, meshes };
          if (key === "e1") {
            const { joints, default_q } = model.robot;
            info.robot = { joints, default_q };
          }
          emit(dir + "manifest.json", JSON.stringify(info));
          copy(dir + "scene.xml", scene_sha256);
          copy(dir + license);
          for (const mesh of Object.values(meshes)) copy(dir + mesh.file, mesh.sha256);
        }
        emit("licenses/three.txt", readFileSync(new URL("./node_modules/three/LICENSE", import.meta.url)));
        for (const name of ["inter-OFL.txt", "intertight-OFL.txt"]) copy("g1/licenses/" + name);
      },
    },
  }],
});
