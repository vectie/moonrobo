import { E1Viewer, loadAssets, loadReplayAssets, verify } from "../e1/viewer.js";
import { robots, frameAt, decodeTrack, validatePanel, guardedPanel, fineTunedPanel } from "./playback.js";

const el = id => document.getElementById(id);
const nameOf = id => id.split("/")[1];
const units = step => (step / panel.control_hz).toFixed(2);
const base = new URL("./heldout/", document.baseURI);
const picker = el("motion"), slider = el("timeline"), play = el("play");
let panel, active, viewers, request, timelineStep = 0, shownStep = -1, playing = false, previousTime = null;
let resumeOnSelect = !matchMedia("(prefers-reduced-motion: reduce)").matches;
const stage = document.querySelector(".lanes");
const variant = new URL(location.href).searchParams.get("e1");
const guarded = variant === "arms-guarded";
const fineTuned = variant === "arm-ft100";
const e1Directory = fineTuned ? "arm-ik/finetune/" : guarded ? "arm-ik/arms-guarded/" : "tracks/";

async function read(path, type = "json", signal) {
  const response = await fetch(new URL(path, base), {signal});
  if (!response.ok) throw Error("Could not load " + path);
  return response[type]();
}

async function createViewers() {
  const [g1, e1] = await Promise.all([
    (async () => {
      const source = (name, type) => read("g1-model/" + name, type);
      const manifest = await source("manifest.json");
      if (manifest.format !== "moonrobo.g1-replay-meshes.v1") throw Error("Unknown G1 model.");
      manifest.robot = {joints: panel.robots.g1.joints, default_q: Array(29).fill(0)};
      return loadReplayAssets(manifest, source);
    })(),
    loadAssets(),
  ]);
  const result = {};
  for (const [i, key] of robots.entries()) {
    const assets = [g1, e1][i];
    if (assets.manifest.scene_sha256 !== panel.robots[key].scene_sha256 ||
        JSON.stringify(assets.manifest.robot.joints) !== JSON.stringify(panel.robots[key].joints)) {
      throw Error("Model and recording joint layout differ.");
    }
    result[key] = new E1Viewer(el(key + "-canvas"), assets, { visualGroup: key === "g1" ? "1" : null });
    result[key].controls.enablePan = false;
  }
  // Copy an orbit relative to the pelvis the camera follows on each robot.
  let syncing = false;
  for (const key of robots) {
    const a = result[key], b = result[key === "g1" ? "e1" : "g1"];
    a.controls.addEventListener("change", () => {
      if (syncing) return;
      syncing = true;
      b.camera.position.copy(a.camera.position).sub(a.controls.target).add(b.controls.target);
      b.controls.update();
      b.render();
      syncing = false;
    });
  }
  return result;
}

function setPlaying(on) {
  playing = on;
  previousTime = null;
  play.textContent = on ? "Pause" : timelineStep >= (active?.clip.expected_steps ?? Infinity) ? "Replay" : "Play";
}

function draw(force = false) {
  if (!active) return;
  const step = Math.floor(timelineStep);
  if (!force && step === shownStep) return;
  shownStep = step;
  const {clip, tracks} = active;
  for (const key of robots) {
    const meta = clip[key], actual = frameAt(step, meta), viewer = viewers[key];
    viewer.pose(tracks[key](step));
    const {x,y} = viewer.root.position, target = viewer.controls.target;
    viewer.camera.position.x += x - target.x;
    viewer.camera.position.y += y - target.y;
    target.x = x;
    target.y = y;
    viewer.render();
    el(key + "-state").textContent = step >= meta.steps ? (meta.completed ? "Completed" : "Stopped · final pose") : "Tracking";
    el(key + "-step").textContent = "Step " + actual.toLocaleString("en-US");
  }
  slider.value = step;
  slider.setAttribute("aria-valuetext", units(step) + " seconds, step " + step);
  el("clock").textContent = units(step) + " / " + units(clip.expected_steps) + " s";
}

function seek(step) {
  if (!active) return;
  timelineStep = Math.min(active.clip.expected_steps, Math.max(0, step));
  setPlaying(false);
  draw();
}

function tick(now) {
  if (active && playing && !document.hidden) {
    if (previousTime !== null) {
      timelineStep = Math.min(active.clip.expected_steps, timelineStep + (now-previousTime) * panel.control_hz * Number(el("speed").value) / 1000);
    }
    previousTime = now;
    draw();
    if (timelineStep >= active.clip.expected_steps) setPlaying(false);
  }
  requestAnimationFrame(tick);
}

function renderOutcomes(clip) {
  el("ends").replaceChildren();
  el("markers").replaceChildren();
  for (const key of robots) {
    const r = clip[key], time = units(r.steps) + " s";
    el(key + "-score").textContent = r.score.toFixed(4);
    el(key + "-end").textContent = (r.completed ? "Full motion" : "Early stop") + " · " + time + " · step " + r.steps.toLocaleString("en-US");
    const button = document.createElement("button");
    button.dataset.robot = key;
    button.textContent = key.toUpperCase() + (r.completed ? " finish" : " stop") + " · " + time + " ↗";
    button.title = "Jump to step " + r.steps + " of " + clip.expected_steps;
    button.onclick = () => seek(r.steps);
    el("ends").append(button);
    const marker = document.createElement("i");
    marker.className = key;
    marker.style.left = (r.steps / clip.expected_steps * 100) + "%";
    el("markers").append(marker);
  }
}

async function choose(clip, autoplay, startStep = 0) {
  request?.abort();
  const controller = new AbortController();
  request = controller;
  setPlaying(false);
  active = null;
  timelineStep = 0;
  shownStep = -1;
  picker.value = clip.id;
  const url = new URL(location.href);
  url.searchParams.set("motion", nameOf(clip.id));
  if (!startStep) url.searchParams.delete("step");
  history.replaceState(null, "", url);
  const alternate = new URL(url);
  if (guarded) alternate.searchParams.delete("e1"); else alternate.searchParams.set("e1", "arms-guarded");
  el("alternate-e1").href = alternate;
  el("study-link").href = "./arm-ik.html?motion=" + encodeURIComponent(nameOf(clip.id)) + (fineTuned ? "#finetune" : "");
  el("orientation-link").href = "./orientation.html?motion=" + encodeURIComponent(nameOf(clip.id));
  el("workflow-link").href = "./workflow.html?motion=" + encodeURIComponent(nameOf(clip.id));
  play.disabled = slider.disabled = true;
  stage.setAttribute("aria-busy","true");
  slider.max = clip.expected_steps; slider.value = 0;
  renderOutcomes(clip);
  el("clock").textContent = "0.00 / " + units(clip.expected_steps) + " s";
  for (const key of robots) {
    el(key + "-state").textContent = "Loading"; el(key + "-step").textContent = "";
  }
  el("notice").textContent = "Loading both recordings…";
  try {
    const tracks = {};
    await Promise.all(robots.map(async key => {
      const meta = clip[key];
      const prefix = key === "e1" ? e1Directory : "tracks/";
      const data = await read(prefix + meta.file, "arrayBuffer", controller.signal);
      await verify(data, meta.sha256);
      tracks[key] = decodeTrack(data, meta, panel.robots[key].joints.length);
    }));
    if (controller.signal.aborted) return;
    for (const key of robots) viewers[key].anchor = tracks[key](0).subarray(0,2);
    active = {clip, tracks};
    stage.setAttribute("aria-busy","false");
    play.disabled = slider.disabled = false;
    el("notice").textContent = "";
    timelineStep = Math.min(clip.expected_steps, Math.max(0, startStep));
    draw(true);
    setPlaying(autoplay);
  } catch (error) {
    if (!controller.signal.aborted) {
      el("notice").textContent = "Replay unavailable. " + error.message;
      for (const key of robots) el(key+"-state").textContent = "Unavailable";
    }
  }
}

async function start() {
  panel = validatePanel(await read("tracks/manifest.json"));
  if (fineTuned) {
    const [scores, poses] = await Promise.all([read("arm-ik/finetune/result.json"), read("arm-ik/finetune/e1/poses.json")]);
    panel = fineTunedPanel(panel, scores, poses);
    el("replay-protocol").textContent = "40 regression motions · G1 14k and fine-tuned E1 · MuJoCo replay";
    el("e1-title").textContent = "Noetix E1 · 14k + 100 updates";
    el("alternate-e1").textContent = "View frozen 14k on the same reference";
    el("orientation-link").textContent = "原版身体朝向";
    el("workflow-link").textContent = "原版差距分析";
  }
  if (guarded) {
    panel = guardedPanel(panel, await read("arm-ik/results.json"));
    el("e1-title").textContent = "Noetix E1 · Geometry-checked IK";
    el("alternate-e1").textContent = "View original E1";
    el("orientation-link").textContent = "原版身体朝向";
    el("workflow-link").textContent = "原版差距分析";
  }
  picker.replaceChildren();
  for (const name of ["dance","karate"]) {
    const group = document.createElement("optgroup");
    group.label = name === "dance" ? "Dance" : "Karate";
    for (const clip of panel.clips.filter(c => c.id.startsWith(name + "/"))) group.append(new Option(nameOf(clip.id), clip.id));
    picker.append(group);
  }
  const requested = new URLSearchParams(location.search).get("motion");
  const first = panel.clips.find(c => c.id === requested || nameOf(c.id) === requested) || panel.clips.find(c => nameOf(c.id) === "M_Move3");
  picker.value = first.id;
  el("notice").textContent = "Loading robot models…";
  viewers = await createViewers();
  picker.disabled = false;
  picker.onchange = () => choose(panel.clips.find(c=>c.id===picker.value), resumeOnSelect);
  play.onclick = () => {
    if (timelineStep >= active.clip.expected_steps) seek(0);
    resumeOnSelect = !playing;
    setPlaying(resumeOnSelect);
  };
  slider.oninput = () => seek(Number(slider.value));
  el("view").onchange = () => {
    viewers.g1.setView(el("view").value);
    if (active) draw(true);
  };
  document.addEventListener("visibilitychange", () => { previousTime = null; });
  requestAnimationFrame(tick);
  const step = new URLSearchParams(location.search).get("step");
  const hasStep = step !== null && /^\d{1,7}$/.test(step);
  await choose(first, hasStep ? false : resumeOnSelect, hasStep ? Number(step) : 0);
}
start().catch(error => { el("notice").textContent = "Could not open the motion comparison. " + error.message; });
