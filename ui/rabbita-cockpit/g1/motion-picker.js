// Folders contain playable references. Experiments change the simulation
// conditions of the chosen reference; they are not extra motions or scores.
export const experiments = [
  ["nominal", "Normal tracking"],
  ["off", "Policy off"],
  ["slip", "Slippery floor"],
  ["noise", "Noisy actions"],
  ["push", "Pelvis push"],
  ["early", "Early checkpoint"],
];
const order = [
  "Acrobatics",
  "Contact rich",
  "Manipulation",
  "Locomotion",
  "Dance",
  "LAFAN1",
  "Evaluation panel",
];
export function motionPicker({
  list,
  search,
  summary,
  choose,
  shuffle,
  experiment,
  settings,
}) {
  let clips = [],
    active = null,
    open = new Set();
  function btn(text, fn, cls) {
    const b = document.createElement("button");
    b.type = "button";
    b.className = cls;
    b.textContent = text;
    b.onclick = fn;
    return b;
  }
  function draw() {
    const term = search.value.trim().toLowerCase(),
      fragment = document.createDocumentFragment();
    let rendered = 0;
    for (const group of [...order, "Experiments"]) {
      const exp = group === "Experiments",
        groupMatch = group.toLowerCase().includes(term);
      const rows = exp
        ? experiments.map(([id, label]) => ({ id, label }))
        : clips.filter((c) => c.group === group);
      const matches = rows.filter(
        (r) =>
          groupMatch ||
          [r.label, r.name].join(" ").toLowerCase().includes(term),
      );
      if (!matches.length) continue;
      const section = document.createElement("div"),
        header = document.createElement("div");
      const expanded = term !== "" || open.has(group);
      const folder = btn(
        group,
        () => {
          if (open.has(group)) open.delete(group);
          else open.add(group);
          draw();
          Array.from(list.querySelectorAll(".folder-name"))
            .find((b) => b.dataset.group === group)
            ?.focus({ preventScroll: true });
        },
        "folder-name",
      );
      folder.dataset.group = group;
      folder.setAttribute("aria-expanded", String(expanded));
      const total = document.createElement("small");
      total.textContent = matches.length;
      folder.append(total);
      header.className = "folder-row";
      header.append(folder);
      if (!exp) {
        const start = btn("⤨", () => shuffle(matches, group), "folder-shuffle");
        start.setAttribute("aria-label", "Shuffle " + group);
        start.title = "Play folder in shuffled order";
        header.append(start);
      }
      section.append(header);
      if (expanded) {
        const inner = document.createElement("div");
        inner.className = "folder-items";
        for (const r of matches) {
          const b = btn(
            r.label,
            () => (exp ? experiment(r.id) : choose(r.index)),
            "motion-item",
          );
          if (!exp) {
            b.title = r.name;
            b.dataset.index = String(r.index);
            b.setAttribute("aria-pressed", String(active === r.index));
          }
          inner.append(b);
        }
        section.append(inner);
      }
      fragment.append(section);
      rendered += matches.length;
    }
    if (!rendered) {
      const none = document.createElement("p");
      none.textContent = "No matching motions or experiments.";
      fragment.append(none);
    }
    list.replaceChildren(fragment);
    summary.textContent =
      clips.length + " motions · " + experiments.length + " experiments";
  }
  search.oninput = draw;
  const more = btn("Settings ›", settings, "picker-settings");
  summary.after(more);
  return {
    setClips(rows) {
      clips = rows;
      draw();
    },
    select(i) {
      active = i;
      for (const b of list.querySelectorAll("[data-index]"))
        b.setAttribute("aria-pressed", String(Number(b.dataset.index) === i));
    },
    clearSearch() {
      search.value = "";
      draw();
    },
  };
}
