import reference from "./elbow-reference.json";
import { RAISED_LAST, raisedPair, raisedPhase } from "./raised-drums.js";
import { E1Viewer, loadAssets } from "./viewer.js";

const element = id => document.getElementById(id);
const oldOffsets = reference.offset_degrees;
const oldPeak = oldOffsets.indexOf(Math.min(...oldOffsets));
const seconds = frame => frame * reference.step_ms / 1000;
const degrees = radians => radians * 180 / Math.PI;
const radians = angle => angle * Math.PI / 180;
const validVector = (values, size) => Array.isArray(values) && values.length === size && values.every(Number.isFinite);
const trace = element("trace"), slider = element("scrub");
const isRaised = () => element("pose-source").value === "raised";
const lastFrame = () => isRaised() ? RAISED_LAST : oldOffsets.length - 1;
let step = 0, started = null, measured, planned, joints, elbow, rightElbow, base, baseOri = [0,0,0,1];
let lastStamp = "", lastNew = -Infinity, shadow;
let curveKey = "", curves = [[], []];

function updateCurves() {
  const left = degrees(base?.[elbow] ?? 0), right = degrees(base?.[rightElbow] ?? 0);
  const key = `${isRaised()}:${left}:${right}`;
  if (key === curveKey) return;
  curveKey = key;
  if (isRaised()) {
    curves = [[], []];
    for (let i = 0; i <= RAISED_LAST; i++) {
      const pair = raisedPair(i, left, right);
      curves[0].push(pair[0]); curves[1].push(pair[1]);
    }
  } else curves = [oldOffsets, []];
}
function drawTrace() {
  updateCurves();
  const w = trace.clientWidth, h = trace.clientHeight, d = devicePixelRatio || 1;
  trace.width = Math.round(w*d); trace.height = Math.round(h*d);
  const ctx = trace.getContext("2d"); ctx.scale(d,d);
  const last = lastFrame(), x = i => 30 + (w-36)*i/last;
  const y = angle => h-7 + (h-14)*angle/90;
  ctx.fillStyle = "#536368"; ctx.font = "12px sans-serif";
  ctx.fillText("90°", 1, 15); ctx.fillText("0°", 7, h-4);
  ctx.strokeStyle = "#cdd9d5"; ctx.beginPath(); ctx.moveTo(x(0), y(0)); ctx.lineTo(x(last), y(0)); ctx.stroke();
  const stride = Math.max(1, Math.floor(last / Math.max(1,w*2)));
  curves.forEach((values, side) => {
    if (!values.length) return;
    ctx.strokeStyle = side ? "#315aa8" : "#006457"; ctx.lineWidth = 2;
    ctx.setLineDash(side ? [6,4] : []); ctx.beginPath();
    ctx.moveTo(x(0), y(values[0]));
    for (let i = stride; i <= last; i += stride) ctx.lineTo(x(i), y(values[i]));
    ctx.lineTo(x(last), y(values[last])); ctx.stroke(); ctx.setLineDash([]);
    ctx.beginPath(); ctx.arc(x(step), y(values[step]), side ? 3 : 4, 0, 2*Math.PI);
    ctx.fillStyle = side ? "#315aa8" : "#006457"; ctx.fill();
  });
}
function reflect(next) {
  step = Math.max(0, Math.min(lastFrame(), next));
  slider.max = lastFrame(); slider.value = step;
  const raised = isRaised(); updateCurves();
  const angle = raised
    ? `左 ${curves[0][step].toFixed(1)}° · 右 ${curves[1][step].toFixed(1)}°`
    : `${oldOffsets[step].toFixed(3)}°`;
  element("delta").textContent = angle;
  element("clock").textContent = `${seconds(step).toFixed(2)} / ${seconds(lastFrame()).toFixed(2)} s`;
  element("trace-heading").textContent = raised ? "双肘目标角度" : "左肘相对起点变化";
  element("preview-phase").textContent = raised ? `预览阶段：${raisedPhase(step)}` : "左肘旧参考 / 已记录影子输出";
  element("right-legend").hidden = !raised;
  element("peak").textContent = raised ? "双肘 90°" : "查看峰值";
  element("left-drop").hidden = element("right-drop").hidden = !raised;
  slider.setAttribute("aria-valuetext", `${seconds(step).toFixed(2)} 秒，${angle}`);
  trace.setAttribute("aria-label", raised ? "双肘抬至 90 度后，左右交替下落 30 度再抬回的预览曲线" : "左肘屈伸参考曲线");
  drawTrace();
  if (!planned) return;
  const recorded = !raised && element("pose-source").value === "shadow" && shadow;
  const q = raised ? base.slice() : recorded ? shadow.nominal[step].slice() : (shadow?.baseline ?? base).slice();
  if (raised) {
    q[elbow] = radians(curves[0][step]); q[rightElbow] = radians(curves[1][step]);
    element("reference-origin").textContent = "以本次采样的起始姿态预览 · 双肘目标 90° ↔ 60°";
  } else if (recorded) {
    element("shadow-angle").textContent = `${degrees(q[elbow]).toFixed(2)}°`;
    element("recorded-angle").textContent = `${degrees(shadow.measured[step][elbow]).toFixed(2)}°`;
  } else {
    q[elbow] += radians(oldOffsets[step]);
    element("reference-origin").textContent = shadow ? "以影子测试首帧实测姿态为起点" : "以本次采样的起始姿态为参考";
  }
  element("reference-caption").hidden = !!recorded; element("shadow-caption").hidden = !recorded;
  planned.pose([0,0,.85,...(raised ? baseOri : shadow?.baseline_ori ?? baseOri),...q]); planned.render();
}
function pause() { started = null; element("play").textContent = "播放预览"; }
function animate(now) {
  if (started === null) return;
  const next = Math.min(lastFrame(), Math.floor((now-started)/reference.step_ms));
  if (next !== step) reflect(next);
  if (next === lastFrame()) pause(); else requestAnimationFrame(animate);
}
element("play").onclick = () => {
  if (started !== null) return pause();
  if (step === lastFrame()) reflect(0);
  started = performance.now() - step*reference.step_ms;
  element("play").textContent = "暂停"; requestAnimationFrame(animate);
};
slider.oninput = () => { pause(); reflect(Number(slider.value)); };
element("peak").onclick = () => { pause(); reflect(isRaised() ? 3000 : oldPeak); };
element("left-drop").onclick = () => { pause(); reflect(3500); };
element("right-drop").onclick = () => { pause(); reflect(4300); };
element("pose-source").onchange = () => { pause(); reflect(0); };
document.addEventListener("visibilitychange", () => { if (document.hidden) pause(); });
new ResizeObserver(drawTrace).observe(trace); reflect(0);

function linkStatus(message, live) {
  const node = element("link-state"); node.dataset.live = String(live);
  if (node.textContent !== message) node.textContent = message;
}
function markOffline(message) {
  linkStatus(lastStamp ? "遥测中断" : "等待遥测", false);
  element("feed-note").hidden = false; element("feed-note").textContent = message;
  element("measured").hidden = true;
  element("measured-angle").textContent = element("measured-right-angle").textContent = "—";
}
async function poll() {
  try {
    const response = await fetch("./__e1_pose", {cache:"no-store",signal:AbortSignal.timeout(800)});
    if (!response.ok) throw Error();
    const s = await response.json();
    if (!Array.isArray(s.names) || s.names.length !== joints.length || new Set(s.names).size !== joints.length ||
        ![s.q,s.baseline].every(v => validVector(v,joints.length)) ||
        ![s.ori,s.baseline_ori].every(v => validVector(v,4) && Math.hypot(...v)>0.5) ||
        typeof s.source_ns !== "string" || !/^\d+$/.test(s.source_ns)) throw Error();
    const slots = joints.map(name => s.names.indexOf(name)); if (slots.includes(-1)) throw Error();
    if (s.source_ns !== lastStamp) {
      lastStamp = s.source_ns; lastNew = performance.now();
      base = slots.map(i => s.baseline[i]); baseOri = s.baseline_ori;
      const q = slots.map(i => s.q[i]);
      element("measured").hidden = false; element("feed-note").hidden = true;
      measured.pose([0,0,.85,...s.ori,...q]); measured.render();
      element("measured-angle").textContent = `${degrees(q[elbow]).toFixed(2)}°`;
      element("measured-right-angle").textContent = `${degrees(q[rightElbow]).toFixed(2)}°`;
      linkStatus("实时 · 只读", true); reflect(step);
    }
    if (performance.now()-lastNew > 1200) throw Error();
  } catch { markOffline(lastStamp ? "实时数据已中断" : "等待只读遥测连接"); }
  finally { setTimeout(poll, document.hidden ? 500 : 90); }
}
async function start() {
  const assets = await loadAssets(); joints = assets.manifest.robot.joints;
  elbow = joints.indexOf(reference.joint); rightElbow = joints.indexOf("r_arm_elbow_pitch_joint");
  if (elbow < 0 || rightElbow < 0) throw Error("模型缺少肘关节");
  base = assets.manifest.robot.default_q;
  measured = new E1Viewer(element("measured"),assets); planned = new E1Viewer(element("planned"),assets);
  for (const viewer of [planned,measured]) { viewer.camera.position.set(1.9,2.8,1.16); viewer.controls.update(); }
  let syncing = false;
  for (const [a,b] of [[measured,planned],[planned,measured]]) {
    a.controls.addEventListener("change", () => {
      if (syncing) return; syncing = true;
      try { b.camera.position.copy(a.camera.position); b.controls.target.copy(a.controls.target); b.controls.update(); b.render(); }
      finally { syncing = false; }
    });
  }
  reflect(step); poll();
  try {
    const response = await fetch("./__e1_shadow", {cache:"no-store",signal:AbortSignal.timeout(2500)});
    if (!response.ok) return;
    const tape = await response.json();
    if (tape.reference?.joint !== reference.joint || tape.reference.step_ms !== reference.step_ms ||
        !validVector(tape.reference.offset_degrees,oldOffsets.length) || !oldOffsets.every((v,i) => v === tape.reference.offset_degrees[i]) ||
        !Array.isArray(tape.names) || tape.names.length !== joints.length || !joints.every((n,i)=>tape.names[i]===n) ||
        !validVector(tape.baseline,joints.length) || !validVector(tape.baseline_ori,4) ||
        ![tape.nominal,tape.measured].every(rows => Array.isArray(rows) && rows.length === oldOffsets.length && rows.every(row => validVector(row,joints.length)))) return;
    shadow = tape; element("pose-source").querySelector('[value="shadow"]').disabled = false; reflect(step);
  } catch { /* Optional recorded output does not affect the live mirror or nominal preview. */ }
}
start().catch(error => {
  element("model-error").hidden = false; element("model-error").textContent = "三维模型载入失败。" + error.message;
  markOffline("三维镜像暂不可用");
});
