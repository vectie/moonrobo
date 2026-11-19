// Editorial controls never load model weights. The lab starts on demand.
const $ = (id) => document.getElementById(id);
export const standalone =
  document.documentElement.classList.contains("demo-only");
const reduce = matchMedia("(prefers-reduced-motion: reduce)");
const hero = $("hero-film"),
  toggle = $("hero-play");
let visible = false,
  requested = !reduce.matches;
function syncFilm() {
  if (!standalone && requested && visible && !document.hidden)
    hero.play().catch(() => {
      requested = false;
      reflect();
    });
  else hero.pause();
}
function reflect() {
  const on = !hero.paused;
  toggle.setAttribute("aria-label", on ? "Pause hero film" : "Play hero film");
  toggle.firstElementChild.textContent = on ? "⏸" : "▶";
}
toggle.onclick = () => {
  requested = hero.paused;
  syncFilm();
};
hero.addEventListener("play", reflect);
hero.addEventListener("pause", reflect);
new IntersectionObserver(([entry]) => {
  visible = entry.isIntersecting;
  syncFilm();
}).observe(hero);
document.addEventListener("visibilitychange", syncFilm);
reduce.addEventListener("change", () => {
  requested = !reduce.matches;
  syncFilm();
});

const menu = $("explore");
menu.addEventListener("click", (e) => {
  if (e.target.closest("a")) menu.open = false;
});
document.addEventListener("click", (e) => {
  if (!menu.contains(e.target)) menu.open = false;
});
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && menu.open) {
    menu.open = false;
    menu.querySelector("summary").focus();
  }
});

const reel = $("reel"),
  dots = [...document.querySelectorAll(".reel-nav button")];
function go(i) {
  const step = reel.children[1].offsetLeft - reel.children[0].offsetLeft;
  reel.scrollTo({
    left: i * step,
    behavior: reduce.matches ? "instant" : "smooth",
  });
}
dots.forEach((d, i) => (d.onclick = () => go(i)));
reel.addEventListener(
  "scroll",
  () => {
    const step = reel.children[1].offsetLeft - reel.children[0].offsetLeft;
    const current = Math.round(reel.scrollLeft / step);
    dots.forEach((d, i) => d.setAttribute("aria-pressed", i === current));
  },
  { passive: true },
);
const qs = [...document.querySelectorAll(".qa")],
  expand = $("expand");
function syncFaq() {
  expand.textContent = qs.every((q) => q.open)
    ? "Collapse all ⌃"
    : "Expand all ⌄";
}
expand.onclick = () => {
  const on = !qs.every((q) => q.open);
  qs.forEach((q) => (q.open = on));
  syncFaq();
};
qs.forEach((q) => q.addEventListener("toggle", syncFaq));

const both = document.querySelectorAll(".paired video");
$("paired-play").onclick = async () => {
  for (const v of both) {
    v.muted = true;
    v.currentTime = 0;
  }
  await Promise.allSettled([...both].map((v) => v.play()));
};
export function drawReturns(rows) {
  if (!rows.length || standalone) return;
  const plot = $("returns-plot"),
    slider = $("inspect-return");
  const x = (i) => 43 + (i * 690) / Math.max(1, rows.length - 1),
    y = (r) => 195 - r * 168;
  const svg = (tag, props, content) => {
    const el = document.createElementNS("http://www.w3.org/2000/svg", tag);
    for (const [k, v] of Object.entries(props)) el.setAttribute(k, v);
    if (content !== undefined) el.textContent = content;
    plot.append(el);
    return el;
  };
  for (const n of [0, 0.25, 0.5, 0.75, 1]) {
    svg("line", { x1: 40, y1: y(n), x2: 739, y2: y(n), stroke: "#dcdce0" });
    svg(
      "text",
      {
        x: 32,
        y: y(n) + 4,
        "text-anchor": "end",
        fill: "#62626a",
        "font-size": 12,
      },
      n.toFixed(2),
    );
  }
  const marker = svg("line", {
    x1: x(0),
    x2: x(0),
    y1: 16,
    y2: 198,
    stroke: "#49494f",
    "stroke-dasharray": "3 3",
  });
  for (const [i, r] of rows.entries()) {
    svg("line", {
      x1: x(i),
      x2: x(i),
      y1: y(r.early_return),
      y2: y(r.final_return),
      stroke: "#cfdcec",
      "stroke-width": 2,
    });
    svg("circle", { cx: x(i), cy: y(r.early_return), r: 3.8, fill: "#83838a" });
    svg("circle", { cx: x(i), cy: y(r.final_return), r: 3.8, fill: "#0071df" });
  }
  svg("text", { x: 40, y: 218, fill: "#62626a", "font-size": 12 }, "1");
  svg(
    "text",
    { x: 739, y: 218, "text-anchor": "end", fill: "#62626a", "font-size": 12 },
    String(rows.length),
  );
  slider.max = rows.length;
  function select(i) {
    const r = rows[i];
    marker.setAttribute("x1", x(i));
    marker.setAttribute("x2", x(i));
    slider.value = i + 1;
    $("return-detail").value =
      i +
      1 +
      "/" +
      rows.length +
      " · " +
      r.clip.split("/").at(-1) +
      " · " +
      r.early_return.toFixed(4) +
      " → " +
      r.final_return.toFixed(4);
  }
  slider.oninput = () => select(Number(slider.value) - 1);
  plot.onpointermove = (e) => {
    const b = plot.getBoundingClientRect();
    select(
      Math.min(
        rows.length - 1,
        Math.max(
          0,
          Math.round(
            ((((e.clientX - b.left) / b.width) * 750 - 43) / 690) *
              (rows.length - 1),
          ),
        ),
      ),
    );
  };
  $("returns-figure").hidden = false;
  select(0);
}
