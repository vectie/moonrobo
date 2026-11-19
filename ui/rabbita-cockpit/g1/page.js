import { motionPicker, experiments } from "./motion-picker.js";
import { standalone, drawReturns } from "./showcase.js";
const $ = (id) => document.getElementById(id);
const status = (text) => {
  $("stage-info").textContent = text;
};
const url = (key) => new URL("g1-data/" + key, document.baseURI);
async function get(address, type = "json", signal) {
  const response = await fetch(address, { signal });
  if (!response.ok)
    throw Error(
      "HTTP " + response.status + " for " + new URL(response.url).pathname,
    );
  return response[type]();
}
let panel,
  lab,
  viewer,
  catalog,
  kernel,
  api,
  launch,
  busy = false,
  ticket = 0;
let playing = false,
  last = 0,
  debt = 0,
  chosen = null;
let frameRequest,
  resumeAt = 0,
  deck = [],
  bag = [],
  experimentId = "nominal";
let inView = true,
  animationFrame = 0;
new IntersectionObserver((entries) => {
  inView = entries[0].isIntersecting;
  if (!inView) last = debt = 0;
}).observe($("stage"));
const packs = new Map(),
  clips = new Map();
function play(on) {
  playing = on;
  last = debt = 0;
  resumeAt = 0;
  $("play").textContent = on ? "Ⅱ" : "▶";
  $("play").setAttribute(
    "aria-label",
    on ? "Pause simulation" : "Play simulation",
  );
}
function telemetry() {
  $("step-count").textContent =
    "Step " + lab.i.toLocaleString("en-US") + " since reset";
  $("clock").textContent =
    (lab.i * 0.02).toFixed(2) +
    " / " +
    ((lab.clip.length - 1) * 0.02).toFixed(2) +
    " s";
  $("drift").textContent = lab.prediction
    ? "Δ root " + (100 * lab.drift).toFixed(1) + " cm"
    : "Prediction off";
}
function advance() {
  lab.step();
  if (lab.end) {
    const repeat = playing && $("repeat").checked;
    play(false);
    if (repeat) resumeAt = performance.now() + 1300;
    status(lab.end + " · frame " + lab.i);
  }
}
function animate(time) {
  if (resumeAt && time >= resumeAt && !document.hidden && inView && !busy) {
    resumeAt = 0;
    if (deck.length) chosen = nextInFolder();
    change().catch((e) => status(e.message));
  }
  if (playing && !busy && !document.hidden && inView) {
    if (last) debt = Math.min(0.06, debt + (time - last) / 1000);
    last = time;
    try {
      while (debt >= 0.02 && playing) {
        debt -= 0.02;
        advance();
      }
    } catch (e) {
      play(false);
      status(e.message);
    }
  } else last = 0;
  if (lab && !busy && !document.hidden && inView) {
    viewer.update(lab);
    telemetry();
  }
  animationFrame = requestAnimationFrame(animate);
}
async function pack(tag) {
  if (!packs.has(tag)) {
    const work = (async () => {
      const meta = await get(url(tag + "/model.json")),
        bytes = await get(url(tag + "/weights.f32"), "arrayBuffer");
      return api.modelFromBytes(meta, bytes, kernel);
    })();
    packs.set(tag, work);
    work.catch(() => packs.delete(tag));
  }
  return packs.get(tag);
}
async function motion(idx, signal) {
  if (clips.has(idx)) return clips.get(idx);
  const info = catalog.clips.find((c) => c.index === idx);
  if (!info) throw Error("Unknown motion");
  const buf = await get(url(info.url), "arrayBuffer", signal);
  if (
    buf.byteLength !== info.frames * 608 ||
    (await api.digest(buf)) !== info.sha256
  )
    throw Error("Reference checksum mismatch");
  signal.throwIfAborted();
  const data = new Float64Array(buf),
    window = new Map();
  const clip = new Proxy(
    { length: info.frames },
    {
      get(target, key) {
        if (typeof key !== "string" || !/^\d+$/.test(key)) return target[key];
        const i = Number(key);
        if (i >= info.frames) return undefined;
        if (!window.has(i)) {
          if (window.size >= 24) window.delete(window.keys().next().value);
          window.set(i, api.frame(data.subarray(i * 76, (i + 1) * 76)));
        }
        return window.get(i);
      },
    },
  );
  if (clips.size >= 2) clips.delete(clips.keys().next().value);
  clips.set(idx, clip);
  return clip;
}
async function change(auto = true) {
  const token = ++ticket;
  frameRequest?.abort();
  frameRequest = new AbortController();
  busy = true;
  play(false);
  status("Loading motion…");
  try {
    const [policy, clip] = await Promise.all([
      pack($("policy").value),
      motion(chosen, frameRequest.signal),
    ]);
    if (token !== ticket) return;
    lab.policy = policy;
    lab.reset(clip);
    lab.setFriction(Number($("mu").value));
    lab.noise = Number($("noise").value);
    lab.power = $("power").checked;
    lab.prediction = $("prediction").checked;
    if (viewer.clipIndex !== chosen) {
      viewer.frameClip(lab);
      viewer.clipIndex = chosen;
    }
    if (experimentId === "push") lab.push();
    title();
    viewer.update(lab);
    telemetry();
    status("");
    play(auto);
  } catch (e) {
    if (token === ticket) throw e;
  } finally {
    if (token === ticket) busy = false;
  }
}
async function init() {
  $("start").disabled = true;
  $("start").textContent = "Opening lab…";
  status("Loading G1 model and physics…");
  const [math, dense, backend, wasm, sim, view, manifest] = await Promise.all([
    import("./model.js"),
    import("./dense.wasm?url"),
    import("@mujoco/mujoco"),
    import("@mujoco/mujoco/mujoco.wasm?url"),
    import("./simulation.js"),
    import("./viewer.js"),
    get(url("manifest.json")),
  ]);
  api = math;
  catalog = manifest;
  kernel = await WebAssembly.compile(await get(dense.default, "arrayBuffer"));
  const [mj, policy, xml] = await Promise.all([
    backend.default({
      locateFile: (name) => (name.endsWith(".wasm") ? wasm.default : name),
    }),
    pack("final"),
    get(url("scene.xml"), "text"),
  ]);
  if (
    mj.mj_versionString() !== "3.15.0" ||
    (await api.digest(new TextEncoder().encode(xml))) !==
      policy.meta.sceneSha256
  )
    throw Error("Wrong G1 scene or engine");
  const vfs = new mj.MjVFS();
  let model;
  try {
    for (let i = 0; i < manifest.meshes.length; i += 5)
      await Promise.all(
        manifest.meshes
          .slice(i, i + 5)
          .map(async (name) =>
            vfs.addBuffer(
              name,
              new Uint8Array(await get(url(name), "arrayBuffer")),
            ),
          ),
      );
    model = mj.MjModel.from_xml_string(xml, vfs);
  } finally {
    vfs.delete();
  }
  lab = new sim.Simulation(mj, model, policy, policy);
  viewer = new view.Viewer($("scene"), model, (x, y) => lab.push(x, y), {
    lane: selectedLane,
  });
  viewer.overlay = { ...overlays };
  picker.setClips(manifest.clips);
  if (chosen === null) {
    const q = new URLSearchParams(location.search).get("motion");
    chosen =
      q !== null && manifest.clips.some((c) => c.index === Number(q))
        ? Number(q)
        : (manifest.clips.find((c) => c.label === "frog jump")?.index ?? 7040);
  }
  await change(!window.matchMedia("(prefers-reduced-motion: reduce)").matches);
  $("poster").hidden = true;
  $("legend").hidden = false;
  $("settings").disabled = false;
  $("settings").hidden = false;
  animationFrame = requestAnimationFrame(animate);
}
function releaseLab() {
  cancelAnimationFrame(animationFrame);
  play(false);
  viewer?.dispose();
  lab?.dispose();
  viewer = lab = launch = null;
  packs.clear();
  clips.clear();
  $("legend").hidden = true;
  $("settings").disabled = true;
  $("settings").hidden = true;
  popup(null);
  picker.clearSearch();
  deck = [];
  bag = [];
  $("clock").textContent = "0.00 s";
  $("drift").textContent = "Δ root —";
  $("start").disabled = false;
  $("poster").hidden = false;
}
function start() {
  return (launch ||= init().catch((e) => {
    releaseLab();
    $("start").textContent = "Retry simulation";
    $("start").disabled = false;
    status("Local demo unavailable · " + e.message);
    throw e;
  }));
}
$("start").onclick = () => start().catch(() => {});
$("stop-lab").onclick = () => {
  if (busy) return;
  releaseLab();
  $("start").textContent = "Start the demo ▶";
  status("");
  $("start").focus();
};
$("policy").onchange = () => {
  experimentId = "custom";
  change().catch((e) => status(e.message));
};
$("mu").oninput = () => {
  const v = Number($("mu").value),
    pct = Math.round(((v - 0.1) / 1.8) * 100);
  $("mu-out").value = pct + "%";
  $("mu-out").title = "Friction coefficient " + v.toFixed(2);
  $("mu").style.setProperty("--fill", pct + "%");
  $("mu").setAttribute(
    "aria-valuetext",
    pct + "%, coefficient " + v.toFixed(2),
  );
  lab?.setFriction(v);
};
$("noise").oninput = () => {
  const v = Number($("noise").value);
  $("noise-out").value = v.toFixed(2);
  $("noise").style.setProperty("--fill", (100 * v) / 0.25 + "%");
  if (lab) lab.noise = v;
};
$("prediction").onchange = () => {
  if (lab) {
    lab.prediction = $("prediction").checked;
    lab.tick = 0;
    syncView();
  }
};
$("power").onchange = () => {
  if (lab) lab.power = $("power").checked;
};
$("reset").onclick = () => change().catch((e) => status(e.message));
$("push").onclick = () => {
  if (lab && !busy && !lab.end) {
    lab.push();
    status("100 N push · 0.1 s");
    play(true);
  }
};
$("play").onclick = () => {
  if (!lab || busy) return;
  if (lab.end) {
    change().catch((e) => status(e.message));
    return;
  }
  play(!playing);
};
$("step").onclick = () => {
  if (!lab || busy || lab.end) return;
  play(false);
  try {
    advance();
    viewer.update(lab);
    telemetry();
  } catch (e) {
    status(e.message);
  }
};
for (const b of document.querySelectorAll("[data-preset]"))
  b.onclick = async () => {
    location.hash = "lab";
    try {
      await start();
      await runExperiment(b.dataset.preset, true);
    } catch (e) {
      status(e.message);
    }
  };
function table() {
  const term = $("search").value.toLowerCase(),
    mode = $("filter").value;
  const rows = panel.per_clip.filter(
    (r) =>
      r.clip.toLowerCase().includes(term) &&
      (mode === "all" || (mode === "fail") === r.final_failed),
  );
  $("count").textContent =
    rows.length + " of " + panel.per_clip.length + " panel motions";
  $("rows").replaceChildren(
    ...rows.map((r) => {
      const tr = document.createElement("tr"),
        cell = (s) => {
          const td = document.createElement("td");
          td.textContent = s;
          tr.append(td);
          return td;
        };
      const c = cell(r.clip.split("/").at(-1)),
        s = document.createElement("small");
      s.textContent = r.final_failed ? "Early termination" : "Completed";
      s.className = r.final_failed ? "fail" : "pass";
      c.append(s);
      cell(r.early_return.toFixed(4));
      cell(r.final_return.toFixed(4));
      cell(r.final_steps + " / " + r.expected_steps);
      const btn = document.createElement("button");
      btn.textContent = "Try ↗";
      btn.setAttribute("aria-label", "Try " + r.clip);
      cell("").append(btn);
      btn.onclick = async () => {
        chosen = r.index;
        location.hash = "lab";
        try {
          await start();
          deck = [];
          bag = [];
          await runExperiment("nominal");
        } catch (e) {
          status(e.message);
        }
      };
      return tr;
    }),
  );
}
$("search").oninput = () => panel && table();
$("filter").onchange = () => panel && table();
get(new URL("g1/panel.json", document.baseURI))
  .then((value) => {
    panel = value;
    drawReturns(panel.per_clip);
    table();
  })
  .catch((e) => {
    $("count").textContent = e.message;
  });
const films = {
  jog: [
    "Sideways jog · iteration 14,000",
    "The simulated robot reaches frame 167 of 167. Green is the reference, ivory is MuJoCo, and copper is the learned prediction.",
  ],
  early: [
    "Sideways jog · iteration 4",
    "The same reference triggers early termination at frame 41 in browser physics.",
  ],
  turn: [
    "360° turn · iteration 14,000",
    "The browser rollout terminates at frame 207 of 518. The recorded APIC evaluation reaches frame 237.",
  ],
};
for (const b of document.querySelectorAll("[data-film]"))
  b.onclick = () => {
    const key = b.dataset.film,
      v = $("film");
    v.pause();
    v.poster = "./g1/" + key + ".webp";
    v.src = "./g1/" + key + ".mp4";
    v.load();
    $("film-title").textContent = films[key][0];
    $("film-detail").textContent = films[key][1];
    for (const other of document.querySelectorAll("[data-film]"))
      other.setAttribute("aria-pressed", String(other === b));
    v.play().catch(() => {});
  };

let selectedLane = "world";
const initialLayers =
  new URLSearchParams(location.search).get("overlay")?.split(",") ?? [];
const overlays = {
  goal: initialLayers.includes("goal"),
  physics: initialLayers.includes("mujoco"),
};
function syncView() {
  const split = $("split-view").checked,
    world = $("prediction").checked;
  selectedLane = split ? "all" : world ? "world" : "physics";
  if (viewer) {
    viewer.lane = selectedLane;
    viewer.overlay = { ...overlays };
    viewer.update(lab);
  }
  for (const b of document.querySelectorAll("[data-lane]")) {
    const k = b.dataset.lane;
    const predictionGhost = world && overlays.physics && !split;
    b.dataset.style = split
      ? "split"
      : k === "world" && predictionGhost
        ? "ghost"
        : "normal";
    b.title = split
      ? "Side-by-side view"
      : {
          world: predictionGhost
            ? "Predicted pose · translucent blue"
            : "Predicted pose · solid",
          goal: "Reference pose · translucent gray (G)",
          physics: "MuJoCo pose · solid (S)",
        }[k];
    b.disabled = k === "physics" && !world && !split;
    b.setAttribute(
      "aria-pressed",
      String(
        k === "world"
          ? world
          : split || overlays[k] || (!world && k === "physics"),
      ),
    );
  }
}
for (const b of document.querySelectorAll("[data-lane]"))
  b.onclick = () => {
    if (!lab) return;
    const k = b.dataset.lane;
    if (k === "world") {
      $("prediction").checked = true;
      if (!lab.prediction) lab.tick = 0;
      lab.prediction = true;
      overlays.goal = overlays.physics = false;
    } else {
      overlays[k] = !overlays[k];
    }
    $("split-view").checked = false;
    syncView();
  };
$("split-view").onchange = syncView;
$("repeat").onchange = () => {
  if (!$("repeat").checked) resumeAt = 0;
};
function popup(which) {
  for (const [id, toggle] of [
    ["motions-drawer", "motions-open"],
    ["lab-options", "options-open"],
  ]) {
    const open = id === which;
    $(id).hidden = !open;
    $(toggle).setAttribute("aria-expanded", String(open));
  }
}
$("motions-open").onclick = () => {
  const open = $("motions-drawer").hidden;
  popup(open ? "motions-drawer" : null);
  if (open) $("motion-search").focus({ preventScroll: true });
};
$("options-open").onclick = () =>
  popup($("lab-options").hidden ? "lab-options" : null);
document.addEventListener("pointerdown", (e) => {
  if (!e.target.closest(".drawer,#motions-open,#options-open,.dock label"))
    popup(null);
});
document.addEventListener("keydown", (e) => {
  if (
    !lab ||
    !inView ||
    document.hidden ||
    e.repeat ||
    e.metaKey ||
    e.ctrlKey ||
    e.altKey
  )
    return;
  if (e.key === "Escape") {
    const toggle = !$("motions-drawer").hidden
      ? "motions-open"
      : !$("lab-options").hidden
        ? "options-open"
        : null;
    if (toggle) {
      popup(null);
      $(toggle).focus();
    }
    return;
  }
  if (
    e.target.closest("input,select,textarea,button,a,summary,[contenteditable]")
  )
    return;
  const btn = { r: "reset", p: "power", " ": "play" }[e.key.toLowerCase()];
  if (btn) {
    e.preventDefault();
    $(btn).click();
  }
  if (e.key === "g" || e.key === "s")
    document
      .querySelector(
        '[data-lane="' + (e.key === "g" ? "goal" : "physics") + '"]',
      )
      .click();
});
function title() {
  const c = catalog.clips.find((c) => c.index === chosen);
  if (!c) return;
  const group = document.createElement("span");
  group.textContent = c.group + " · ";
  $("motion-title").replaceChildren(group, document.createTextNode(c.label));
  $("motions-open").title =
    c.name + " · " + $("policy").selectedOptions[0].textContent;
  picker.select(chosen);
}
function nextInFolder() {
  if (!bag.length) {
    bag = [...deck];
    for (let i = bag.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [bag[i], bag[j]] = [bag[j], bag[i]];
    }
    if (bag.length > 1 && bag.at(-1) === chosen)
      [bag[0], bag[bag.length - 1]] = [bag.at(-1), bag[0]];
  }
  return bag.pop();
}
async function runExperiment(id, compare = false) {
  experimentId = id;
  $("policy").value = id === "early" ? "early" : "final";
  $("power").checked = id !== "off";
  $("prediction").checked = true;
  $("mu").value = id === "slip" ? 0.2 : 1;
  $("mu").oninput();
  $("noise").value = id === "noise" ? 0.12 : 0;
  $("noise").oninput();
  if (compare) overlays.physics = true;
  $("split-view").checked = false;
  syncView();
  await change();
  status(experiments.find(([k]) => k === id)?.[1] || "");
}
const picker = motionPicker({
  list: $("motion-folders"),
  search: $("motion-search"),
  summary: $("library-size"),
  choose: (i) => {
    chosen = i;
    deck = [];
    bag = [];
    change().catch((e) => status(e.message));
  },
  shuffle: (matches) => {
    deck = matches.map((c) => c.index);
    bag = [];
    chosen = nextInFolder();
    $("repeat").checked = true;
    change().catch((e) => status(e.message));
  },
  experiment: (id) => {
    popup(null);
    runExperiment(id).catch((e) => status(e.message));
  },
  settings: () => popup("lab-options"),
});
const compact = matchMedia("(max-width:800px)"),
  conditions = ["power", "noise", "mu"].map((id) => $(id).closest("label"));
const mobileConditions = document.createElement("div");
mobileConditions.className = "mobile-conditions";
$("lab-options").prepend(mobileConditions);
function fitConditions() {
  for (const el of conditions) {
    if (compact.matches) mobileConditions.append(el);
    else $("motions-open").before(el);
  }
}
compact.addEventListener("change", fitConditions);
fitConditions();
syncView();
if (standalone) start().catch(() => {});
