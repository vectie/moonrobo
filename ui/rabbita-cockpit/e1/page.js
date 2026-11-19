import { chartPoints, estimateRate, validateStatus } from "./status.js";
const $ = (id) => document.getElementById(id);
const reduce = matchMedia("(prefers-reduced-motion: reduce)");
const names = { dance1: "舞蹈", "0_boxing": "拳击 I", "135_02": "动作 135_02", "02_boxing": "拳击 II" };
const playIcon = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m9 5 11 7-11 7Z" /></svg>';
const pauseIcon = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M8 5h2v14H8zM15 5h2v14h-2z" /></svg>';
let hero, viewer, assets, clip, frame = 0, playing = false, rotating = !reduce.matches, looping = true, last = 0, busy = true, ticket = 0;
const clips = new Map();
const libraries = new Map();
const modelPicker = $("replay-model"), motionPicker = $("replay-motion");
function selectLibrary(key, preferred) {
  const motions = libraries.get(key);
  const selected = motions.find(m => m.id === preferred?.id || (preferred?.clip_id && m.clip_id === preferred.clip_id))
    ?? motions.find(m => m.panel_index === 10) ?? motions[0];
  modelPicker.value = key;
  motionPicker.replaceChildren(...motions.map(m => {
    const title = m.title ?? names[m.id] ?? m.id;
    const outcome = m.completed === false ? " · 提前终止" : "";
    return new Option(title + outcome, m.id);
  }));
  motionPicker.value = selected.id;
  return choose(selected.id, selected.kind === "policy-rollout");
}
modelPicker.onchange = () => {
  const previous = assets.manifest.clips.find(m => m.id === motionPicker.value);
  selectLibrary(modelPicker.value, previous);
};
motionPicker.onchange = () => choose(motionPicker.value);
function play(on) {
  playing = on;
  last = 0;
  $("play").innerHTML = on ? pauseIcon : playIcon;
  $("play").setAttribute("aria-label", on ? "暂停动作" : "播放动作");
}
function reflectFrame() {
  const i = Math.min(clip.meta.frames - 1, Math.floor(frame));
  const row = clip.values.subarray(i * clip.meta.width, (i + 1) * clip.meta.width);
  viewer.pose(row);
  // Follow horizontal root translation while preserving the orbit direction.
  const x = viewer.root.position.x, y = viewer.root.position.y;
  viewer.camera.position.x += x - viewer.controls.target.x;
  viewer.camera.position.y += y - viewer.controls.target.y;
  viewer.controls.target.x = x; viewer.controls.target.y = y;
  viewer.render();
  $("timeline").value = String(i);
  $("timeline").setAttribute("aria-valuetext", `${(i / 50).toFixed(2)} 秒`);
  $("clip-clock").textContent = `${(i / 50).toFixed(2)} / ${((clip.meta.frames - 1) / 50).toFixed(2)} s`;
}
async function choose(id, autoplay = true) {
  const request = ++ticket;
  busy = true;
  play(false);
  $("motion-stage").setAttribute("aria-busy", "true");
  $("stage-loading").hidden = false;
  $("stage-loading").textContent = "正在读取动作…";
  $("play").disabled = $("timeline").disabled = true;
  try {
    const meta = assets.manifest.clips.find((c) => c.id === id);
    if (!meta) throw Error("未找到动作");
    if (!clips.has(id)) {
      const { loadFile, verify } = await import("./viewer.js");
      const buffer = await loadFile(meta.file, "arrayBuffer");
      await verify(buffer, meta.sha256);
      const values = new Float32Array(buffer);
      if (values.length !== meta.frames * meta.width || values.some((v) => !Number.isFinite(v))) throw Error("动作数据不完整");
      clips.set(id, { meta, values });
    }
    if (request !== ticket) return;
    clip = clips.get(id);
    frame = 0;
    viewer.anchor = [clip.values[0], clip.values[1]];
    viewer.setView(document.querySelector("[data-view][aria-pressed=true]").dataset.view);
    const rollout = meta.kind === "policy-rollout";
    $("clip-title").textContent = meta.title ?? names[id];
    $("clip-source").textContent = rollout ? (meta.panel_index != null ? "重训策略 · MuJoCo 回放" : "旧策略 · MuJoCo 回放") : "供应商参考动作";
    $("clip-split").textContent = rollout ? `第 ${meta.checkpoint.toLocaleString("en-US")} 轮` : "历史参考库";
    const steps = meta.frames - 1;
    $("replay-outcome").textContent = rollout ? `${meta.completed === false ? "提前终止" : "完整执行"} · ${steps}/${meta.expected_steps ?? steps} 步 · 回报 ${meta.normalized_return.toFixed(3)}` : `${(steps / 50).toFixed(1)} 秒`;
    $("timeline").max = String(steps);
    const url = new URL(location.href); url.searchParams.set("motion", id); history.replaceState(null, "", url);
    $("play").disabled = $("timeline").disabled = false;
    $("stage-loading").hidden = true;
    busy = false;
    reflectFrame();
    play(autoplay && !reduce.matches);
  } catch (error) {
    if (request !== ticket) return;
    $("stage-loading").textContent = `${error.message}，请选择动作重试。`;
    busy = true;
  } finally { if (request === ticket) $("motion-stage").setAttribute("aria-busy", "false"); }
}
$("play").onclick = () => {
  if (frame >= clip.meta.frames - 1) frame = 0;
  play(!playing); reflectFrame();
};
$("timeline").addEventListener("input", () => { play(false); frame = Number($("timeline").value); reflectFrame(); });
$("repeat").onclick = () => { looping = !looping; $("repeat").setAttribute("aria-pressed", String(looping)); };
function reflectRotation() {
  $("hero-rotate").setAttribute("aria-pressed", String(rotating));
  $("hero-rotate").setAttribute("aria-label", rotating ? "暂停模型旋转" : "旋转模型");
  $("hero-rotate").innerHTML = rotating ? pauseIcon : '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M19 8a8 8 0 1 0 1 7M19 3v5h-5" /></svg>';
}
$("hero-rotate").onclick = () => { rotating = !rotating; reflectRotation(); };
reduce.addEventListener("change", () => { if (reduce.matches) { rotating = false; play(false); reflectRotation(); } });
document.querySelectorAll("[data-view]").forEach((button) => {
  button.onclick = () => {
    if (!viewer) return;
    document.querySelectorAll("[data-view]").forEach((b) => b.setAttribute("aria-pressed", String(b === button)));
    viewer.setView(button.dataset.view);
    if (clip) reflectFrame();
  };
});
function animate(time) {
  const delta = last ? Math.min((time - last) / 1000, .1) : 0;
  last = time;
  if (!document.hidden) {
    if (hero?.visible && rotating) { hero.controls.autoRotate = true; hero.controls.update(delta); }
    else if (hero) hero.controls.autoRotate = false;
    if (viewer?.visible && playing && !busy) {
      frame += delta * 50 * Number($("speed").value);
      if (frame >= clip.meta.frames - 1) {
        if (looping) frame %= clip.meta.frames - 1;
        else { frame = clip.meta.frames - 1; play(false); }
      }
      reflectFrame();
    }
  }
  requestAnimationFrame(animate);
}
document.addEventListener("visibilitychange", () => { last = 0; });
async function start() {
  try {
    const { E1Viewer, loadAssets, loadFile } = await import("./viewer.js");
    const [model, final, mid, calibrated, original] = await Promise.all([
      loadAssets(), loadFile("retrained-14000/manifest.json"), loadFile("retrained-7000/manifest.json"),
      loadFile("panel-7000-anatomical/manifest.json"), loadFile("panel-7000/manifest.json"),
    ]);
    assets = model;
    libraries.set("14000", final.clips);
    libraries.set("7000", mid.clips);
    libraries.set("calibrated", calibrated.clips);
    libraries.set("original", original.clips);
    libraries.set("references", model.manifest.clips);
    assets.manifest.clips = [...libraries.values()].flat();
    hero = new E1Viewer($("hero-canvas"), assets, { hero: true });
    viewer = new E1Viewer($("motion-canvas"), assets);
    $("model-loading").hidden = true;
    $("hero-rotate").disabled = false;
    reflectRotation();
    const requested = new URLSearchParams(location.search).get("motion");
    const key = [...libraries.keys()].find(k => libraries.get(k).some(m => m.id === requested)) ?? "14000";
    modelPicker.disabled = motionPicker.disabled = false;
    await selectLibrary(key, {id: requested});
    requestAnimationFrame(animate);
  } catch (error) {
    $("model-loading").textContent = $("stage-loading").textContent = `${error.message}。请刷新页面重试；三维展示需要 WebGL。`;
    $("motion-stage").setAttribute("aria-busy", "false");
  }
}
start();

const number = new Intl.NumberFormat("en-US");
const date = (value) => new Intl.DateTimeFormat("zh-CN", { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false, timeZone: "Asia/Shanghai" }).format(new Date(value));
function svg(tag, attrs, content) {
  const node = document.createElementNS("http://www.w3.org/2000/svg", tag);
  Object.entries(attrs).forEach(([k, v]) => node.setAttribute(k, v));
  if (content !== undefined) node.textContent = content;
  return node;
}
function drawChart(points) {
  const plot = $("loss-plot"), rows = chartPoints(points);
  plot.replaceChildren();
  if (!rows.length) { plot.append(svg("text", { x: 320, y: 130, "text-anchor": "middle", fill: "#606067", "font-size": 14 }, "暂无可用损失数据")); return; }
  const first = rows[0].iteration, lastRow = rows.at(-1), max = Math.max(...rows.map((p) => p.world_loss)) * 1.06;
  const x = (v) => 48 + (v - first) / Math.max(1, lastRow.iteration - first) * 570;
  const y = (v) => 220 - v / Math.max(.001, max) * 200;
  for (let i = 0; i <= 4; i++) {
    const value = max * i / 4, yy = y(value);
    plot.append(svg("line", { x1: 48, x2: 618, y1: yy, y2: yy, stroke: "#dcdce0", "stroke-dasharray": i ? "3 5" : "none" }));
    plot.append(svg("text", { x: 39, y: yy + 4, "text-anchor": "end", fill: "#606067", "font-size": 11 }, value.toFixed(2)));
  }
  const d = rows.map((p, i) => `${i ? "L" : "M"}${x(p.iteration).toFixed(2)},${y(p.world_loss).toFixed(2)}`).join(" ");
  plot.append(svg("path", { d: `${d} L618,220 L48,220 Z`, fill: "#006f63", opacity: .06 }));
  plot.append(svg("path", { d, fill: "none", stroke: "#006f63", "stroke-width": 2, "stroke-linejoin": "round" }));
  plot.append(svg("circle", { cx: x(lastRow.iteration), cy: y(lastRow.world_loss), r: 3.5, fill: "#006f63" }));
  for (const p of [rows[0], rows[Math.floor(rows.length / 2)], lastRow]) plot.append(svg("text", { x: x(p.iteration), y: 245, "text-anchor": "middle", fill: "#606067", "font-size": 11 }, number.format(p.iteration)));
  plot.setAttribute("aria-label", `世界模型损失，第 ${first} 至 ${lastRow.iteration} 轮；最新 ${points.at(-1).world_loss.toFixed(5)}`);
}
let refreshing = false, lastData;
async function refreshStatus() {
  if (refreshing) return;
  refreshing = true;
  $("refresh-status").disabled = true;
  try {
    let data, live = false;
    try {
      const response = await fetch(new URL("./__e1/status", document.baseURI), { cache: "no-store", signal: AbortSignal.timeout(22000) });
      if (!response.ok) throw Error("无实时连接");
      data = validateStatus(await response.json()); live = true;
    } catch {
      if (lastData) data = lastData;
      else {
        const response = await fetch(new URL("./e1/training.json", document.baseURI), { cache: "no-store" });
        if (!response.ok) throw Error("训练记录暂不可用");
        data = validateStatus(await response.json());
      }
    }
    lastData = data;
    const fresh = Date.now() - Date.parse(data.observed_at) < 120000;
    const labels = { running: "训练中", completed: "训练已结束", stopped: "训练已停止", failed: "训练异常" };
    const label = !live || !fresh ? `记录：${labels[data.state]}` : labels[data.state];
    $("training-badge").textContent = label;
    $("hero-state").textContent = label;
    $("hero-iteration").textContent = `第 ${number.format(data.iteration)} 轮`;
    $("iteration").textContent = number.format(data.iteration);
    $("progress-fill").style.width = `${data.iteration / 140}%`;
    $("training-progress").setAttribute("aria-valuenow", String(data.iteration));
    $("progress-percent").textContent = `${(data.iteration / 140).toFixed(1)}%`;
    $("phase").textContent = data.state === "completed" ? "训练已完成" : data.iteration < 500 ? "世界模型预热" : "世界模型 + 策略 + 价值";
    $("checkpoint").textContent = data.checkpoint ? `第 ${number.format(data.checkpoint.iteration)} 轮` : "尚未保存";
    if (Number.isInteger(data.environments)) {
      $("environment-count").textContent = number.format(data.environments);
      $("current-config").textContent = `${data.environments} 环境 · W${data.world_window} / H${data.horizon}`;
    }
    $("status-freshness").textContent = `${data.anatomical_retrain ? "手臂校准后重训 · " : ""}${live && fresh ? "已连接 Spark · 每 30 秒刷新" : "状态快照 · 当前未实时连接"} · ${date(data.observed_at)}（北京时间）`;
    const rate = estimateRate(data.points);
    $("chart-note").textContent = `实测日志${rate ? ` · 当前阶段约 ${rate.toFixed(2)} 秒/轮` : ""} · 不代表动作完成率`;
    $("latest-loss").textContent = data.points.length ? data.points.at(-1).world_loss.toFixed(5) : "—";
    drawChart(data.points.slice(-300));
  } catch (error) {
    $("training-badge").textContent = "状态暂不可用";
    $("status-freshness").textContent = `${error.message}，可稍后刷新。`;
  } finally { refreshing = false; $("refresh-status").disabled = false; }
}
$("refresh-status").onclick = refreshStatus;
refreshStatus();
setInterval(() => { if (!document.hidden) refreshStatus(); }, 30000);
