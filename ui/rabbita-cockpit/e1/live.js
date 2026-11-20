import reference from "./elbow-reference.json";
import { RAISED_LAST, raisedPair, raisedPhase } from "./raised-drums.js";
import { E1Viewer, loadAssets } from "./viewer.js";
import { parseGestureReplay, replayFrameAt, replayCurves } from "./gesture-replay.js";
import { TRANSFER_LAST, elbowTransferPair, elbowTransferPhase } from "./elbow-transfer.js";

const element = id => document.getElementById(id);
const oldOffsets = reference.offset_degrees;
const oldPeak = oldOffsets.indexOf(Math.min(...oldOffsets));
const seconds = frame => (isGesture() ? gesture.frames[frame].at_ms : frame * reference.step_ms) / 1000;
const degrees = radians => radians * 180 / Math.PI;
const radians = angle => angle * Math.PI / 180;
const validVector = (values, size) => Array.isArray(values) && values.length === size && values.every(Number.isFinite);
const trace = element("trace"), slider = element("scrub");
const isTransfer = () => !!gesture && element("pose-source").value === "elbow-transfer";
const isRaised = () => element("pose-source").value === "raised" || isTransfer();
const isGesture = () => !!gesture && element("pose-source").value.startsWith("typing-");
const lastFrame = () => isGesture() ? gesture.frames.length - 1 : isTransfer() ? TRANSFER_LAST : isRaised() ? RAISED_LAST : oldOffsets.length - 1;
let step = 0, started = null, measured, planned, joints, elbow, rightElbow, base, baseOri = [0,0,0,1];
let lastStamp = "", lastNew = -Infinity, shadow;
let gesture;
let curveKey = "", curves = [[], []];

function updateCurves() {
  if (isGesture()) {
    const key = `typing:${element("trace-joint").value}`;
    if (key !== curveKey) {
      curveKey = key; curves = replayCurves(gesture, Number(element("trace-joint").value));
    }
    return;
  }
  const left = degrees(base?.[elbow] ?? 0), right = degrees(base?.[rightElbow] ?? 0);
  const key = `${isRaised()}:${isTransfer()}:${left}:${right}`;
  if (key === curveKey) return;
  curveKey = key;
  if (isRaised()) {
    curves = [[], []];
    for (let i = 0; i <= lastFrame(); i++) {
      const pair = isTransfer()
        ? elbowTransferPair(i, left, right, degrees(gesture.frames[0].reference[7+elbow]), degrees(gesture.frames[0].reference[7+rightElbow]))
        : raisedPair(i, left, right);
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
  const minimum = isGesture() ? Math.min(...curves.flat()) - 1 : -90;
  const maximum = isGesture() ? Math.max(...curves.flat()) + 1 : 0;
  const y = isGesture() ? angle => 7+(h-14)*(maximum-angle)/(maximum-minimum) : angle => h-7 + (h-14)*angle/90;
  ctx.fillStyle = "#536368"; ctx.font = "12px sans-serif";
  ctx.fillText(isGesture() ? `${maximum.toFixed(0)}°` : "90°", 1, 15); ctx.fillText(isGesture() ? `${minimum.toFixed(0)}°` : "0°", 1, h-4);
  const axis = Math.max(minimum, Math.min(maximum, 0));
  ctx.strokeStyle = "#cdd9d5"; ctx.beginPath(); ctx.moveTo(x(0), y(axis)); ctx.lineTo(x(last), y(axis)); ctx.stroke();
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
  element("trace-joint-label").hidden = !isGesture();
  element("viewport-play").hidden = !isGesture() && !isTransfer();
  element("planned-heading").textContent = isGesture() ? "记录回放" : "动作预览";
  if (gesture) {
    element("replay-note").hidden = !isGesture() && !isTransfer();
    element("replay-note").textContent = isTransfer()
      ? "双肘过渡预览：仅改变左右肘屈伸，腿部、肩部与其余目标保持起始值。网页播放不会启动实机。"
      : "站立打字：参考中的最大腿部关节变化约 2.10°。记录的 Actor 左踝目标约 20–37°，因此完整动作未在实机执行。左侧为当前实时遥测。";
  }
  element("reference-detail").textContent = isGesture() ? " · 根部位置固定" : " · 其余关节保持起始角度";
  if (isGesture()) return reflectGesture();
  const raised = isRaised(); updateCurves();
  const angle = raised
    ? `左 ${curves[0][step].toFixed(1)}° · 右 ${curves[1][step].toFixed(1)}°`
    : `${oldOffsets[step].toFixed(3)}°`;
  element("delta").textContent = angle;
  element("clock").textContent = `${seconds(step).toFixed(2)} / ${seconds(lastFrame()).toFixed(2)} s`;
  element("trace-heading").textContent = raised ? "双肘目标角度" : "左肘相对起点变化";
  element("preview-phase").textContent = isTransfer() ? elbowTransferPhase(step) : raised ? `预览阶段：${raisedPhase(step)}` : "左肘旧参考 / 已记录影子输出";
  element("right-legend").hidden = !raised;
  element("left-legend").textContent = "左肘（实线）";
  element("right-legend").textContent = "右肘（虚线）";
  element("peak").textContent = isTransfer() ? "查看双肘姿态" : raised ? "双肘 90°" : "查看峰值";
  element("left-drop").hidden = element("right-drop").hidden = !raised || isTransfer();
  slider.setAttribute("aria-valuetext", `${seconds(step).toFixed(2)} 秒，${angle}`);
  trace.setAttribute("aria-label", isTransfer() ? "双肘平滑进入打字参考姿态、保持后返回起始姿态的预览曲线" : raised ? "双肘抬至 90 度后，左右交替下落 30 度再抬回的预览曲线" : "左肘屈伸参考曲线");
  drawTrace();
  if (!planned) return;
  const recorded = !raised && element("pose-source").value === "shadow" && shadow;
  const q = raised ? base.slice() : recorded ? shadow.nominal[step].slice() : (shadow?.baseline ?? base).slice();
  if (raised) {
    q[elbow] = radians(curves[0][step]); q[rightElbow] = radians(curves[1][step]);
    element("reference-origin").textContent = isTransfer() ? "当前采样起始姿态 → 打字参考的双肘姿态 → 原姿态；这是过渡预览" : "以本次采样的起始姿态预览 · 双肘目标 90° ↔ 60°";
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
function reflectGesture() {
  updateCurves();
  const actor = element("pose-source").value === "typing-actor";
  const values = `参考 ${curves[0][step].toFixed(1)}° · Actor ${curves[1][step].toFixed(1)}°`;
  element("delta").textContent = values;
  element("clock").textContent = `${seconds(step).toFixed(2)} / ${seconds(lastFrame()).toFixed(2)} s`;
  element("trace-heading").textContent = "参考角度与 Actor 目标";
  element("preview-phase").textContent = `站立打字 · ${gesture.frames.length} 帧影子记录 · 实机未执行该动作`;
  element("left-legend").textContent = "参考（实线）";
  element("right-legend").textContent = "Actor 目标（虚线）";
  element("right-legend").hidden = false;
  element("peak").textContent = "最大目标差";
  element("left-drop").hidden = element("right-drop").hidden = true;
  element("reference-caption").hidden = false; element("shadow-caption").hidden = true;
  element("reference-origin").textContent = actor ? "Ascend 影子测试记录的 PD 目标，未发送；不代表物理运动预测" : "训练参考在 E1 模型上的回放，不是实机动作记录";
  slider.setAttribute("aria-valuetext", `${seconds(step).toFixed(2)} 秒，${values}`);
  trace.setAttribute("aria-label", "所选关节的训练参考角度与记录的 Actor PD 目标对比曲线");
  drawTrace();
  if (planned) {
    planned.pose(gesture.frames[step][actor ? "actor" : "reference"]); planned.render();
  }
}
function pause() {
  started = null; element("play").textContent = isGesture() ? "播放回放" : "播放预览";
  element("viewport-play").textContent = isTransfer() ? "播放过渡预览" : "播放回放";
}
function animate(now) {
  if (started === null) return;
  const elapsed = now-started;
  const next = isGesture() ? replayFrameAt(gesture, elapsed) : Math.min(lastFrame(), Math.floor(elapsed/reference.step_ms));
  if (next !== step) reflect(next);
  if (next === lastFrame()) pause(); else requestAnimationFrame(animate);
}
element("play").onclick = () => {
  if (started !== null) return pause();
  if (step === lastFrame()) reflect(0);
  started = performance.now() - seconds(step)*1000;
  element("play").textContent = "暂停"; element("viewport-play").textContent = isTransfer() ? "暂停预览" : "暂停回放"; requestAnimationFrame(animate);
};
element("viewport-play").onclick = () => element("play").click();
slider.oninput = () => { pause(); reflect(Number(slider.value)); };
element("peak").onclick = () => {
  pause();
  if (isGesture()) {
    updateCurves();
    const differences = curves[0].map((v,i) => Math.abs(v-curves[1][i]));
    return reflect(differences.indexOf(Math.max(...differences)));
  }
  reflect(isRaised() ? 3000 : oldPeak);
};
element("left-drop").onclick = () => { pause(); reflect(3500); };
element("right-drop").onclick = () => { pause(); reflect(4300); };
element("pose-source").onchange = () => { pause(); reflect(0); };
element("trace-joint").onchange = () => reflect(step);
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
  const jointLabels = {hip_yaw:"髋旋转",hip_roll:"髋侧摆",hip_pitch:"髋屈伸",knee:"膝",ankle_pitch:"踝俯仰",ankle_roll:"踝侧摆",
    shoulder_pitch:"肩俯仰",shoulder_roll:"肩侧摆",shoulder_yaw:"肩旋转",elbow_pitch:"肘屈伸",elbow_yaw:"肘旋转",waist_yaw:"腰旋转"};
  joints.forEach((joint, i) => {
    const option = document.createElement("option"); option.value = i;
    const key = joint.replace(/_joint$/, "").replace(/^[lr]_(leg|arm)_/, "");
    option.textContent = (joint.startsWith("l_") ? "左 · " : joint.startsWith("r_") ? "右 · " : "") + (jointLabels[key] ?? key);
    element("trace-joint").append(option);
  });
  element("trace-joint").value = joints.indexOf("l_leg_ankle_roll_joint");
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
  loadGesture();
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
async function loadGesture() {
  try {
    const response = await fetch("./__e1_replay", {cache:"no-store",signal:AbortSignal.timeout(5000)});
    if (!response.ok) throw Error();
    gesture = parseGestureReplay(await response.json(), joints);
    for (const option of element("pose-source").querySelectorAll('[value^="typing-"]')) option.disabled = false;
    element("pose-source").querySelector('[value="elbow-transfer"]').disabled = false;
    element("pose-source").value = new URLSearchParams(location.search).get("gesture") === "elbows" ? "elbow-transfer" : "typing-reference";
    element("replay-note").hidden = false;
    element("replay-note").textContent = "站立打字：参考中的最大腿部关节变化约 2.10°。记录的 Actor 左踝目标约 20–37°，因此这段动作未在实机执行。左侧为当前实时遥测。";
    pause(); reflect(0);
    const play = new URLSearchParams(location.search).get("play") === "1";
    if (play && !matchMedia("(prefers-reduced-motion: reduce)").matches) element("play").click();
  } catch {
    element("replay-note").hidden = false;
    element("replay-note").textContent = "站立打字记录暂不可用；其他参考预览仍可使用。";
  }
}
start().catch(error => {
  element("model-error").hidden = false; element("model-error").textContent = "三维模型载入失败。" + error.message;
  markOffline("三维镜像暂不可用");
});
