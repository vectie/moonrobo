// Local licensed references and weights are served only by explicit opt-in.
// No dataset or weights are copied into dist by the regular cockpit build.
import fs from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";
const MAX_CLIP_BYTES = 16 * 1024 * 1024;
export function localModelData(root) {
  function attach(server) {
    const files = new Map();
    let manifest;
    function index() {
      const read = (p) =>
        JSON.parse(fs.readFileSync(path.join(root, p), "utf8"));
      const mapping = read("source/panel-sources.json");
      const panel = JSON.parse(
        fs.readFileSync(
          new URL("../public/g1/panel.json", import.meta.url),
          "utf8",
        ),
      );
      const scene = fs.readFileSync(
        path.join(root, "source/g1/scene.xml"),
        "utf8",
      );
      const hash = (x) => createHash("sha256").update(x).digest("hex");
      const pins = JSON.parse(
        fs.readFileSync(
          new URL("../public/g1/checkpoints.json", import.meta.url),
          "utf8",
        ),
      );
      if (hash(scene) !== pins.scene_sha256)
        throw Error("Scene digest mismatch");
      // Match scene_assets_hash in the native evaluator (length-first directory ordering).
      const inventory = createHash("sha256");
      function visit(rel) {
        const f = path.join(root, "source/g1", rel),
          s = fs.lstatSync(f);
        if (s.isDirectory()) {
          for (const name of fs
            .readdirSync(f)
            .sort(
              (a, b) => a.length - b.length || (a < b ? -1 : a > b ? 1 : 0),
            ))
            visit(path.join(rel, name));
        } else if (s.isFile())
          inventory.update(
            rel.length + ":" + rel + ":" + hash(fs.readFileSync(f)) + "\n",
          );
        else throw Error("Unexpected scene asset");
      }
      visit("");
      if (inventory.digest("hex") !== pins.scene_assets_sha256)
        throw Error("Scene asset inventory mismatch");
      for (const tag of ["early", "final"]) {
        const m = read("private/" + tag + "/model.json"),
          pin = pins[tag];
        if (
          m.iteration !== pin.iteration ||
          m.sceneSha256 !== pins.scene_sha256 ||
          m.sourceFiles["policy.pt"] !== pin.policy ||
          m.sourceFiles["state.json"] !== pin.state ||
          (tag === "final" && m.sourceFiles["world.pt"] !== pin.world)
        )
          throw Error("Wrong checkpoint for " + tag);
      }
      const meshes = [
        ...new Set(
          [...scene.matchAll(/file="(meshes\/[A-Za-z0-9_]+\.STL)"/g)].map(
            (m) => m[1],
          ),
        ),
      ];
      if (!meshes.length || mapping.length !== panel.per_clip.length)
        throw Error("Incomplete browser bundle");
      for (const key of ["early", "final"])
        for (const f of ["model.json", "weights.f32"])
          files.set(key + "/" + f, "private/" + key + "/" + f);
      files.set("scene.xml", "source/g1/scene.xml");
      for (const f of meshes) files.set(f, "source/g1/" + f);
      const clips = panel.per_clip.map((row, i) => {
        const { i: idx, s } = mapping[i];
        if (idx !== row.index || !/^[a-f0-9]{64}$/.test(s))
          throw Error("Panel identity mismatch");
        const key = hash("moonrobo.motion-shard.f64le.v1:" + s + ":120"),
          rel = "source/clips/" + key.slice(0, 2) + "/" + key + ".f64";
        const meta = read(rel + ".json");
        if (meta.source_sha256 !== s || meta.frames !== row.expected_steps + 1)
          throw Error("Unmatched motion shard");
        const url = "clips/" + idx + ".f64";
        files.set(url, rel);
        return {
          index: idx,
          name: row.clip,
          group: "Evaluation panel",
          label: row.clip
            .split("/")
            .at(-1)
            .replace(/__.*$/, "")
            .replaceAll("_", " "),
          frames: meta.frames,
          sha256: meta.state_sha256,
          url,
        };
      });
      if (fs.existsSync(path.join(root, "source/showcase-clips"))) {
        const menu = JSON.parse(
          fs.readFileSync(
            new URL("./showcase-motions.json", import.meta.url),
            "utf8",
          ),
        );
        const bytes = fs.readFileSync(path.join(root, "source/catalog.json"));
        if (
          hash(bytes) !== menu.catalogSha256 ||
          read("source/receipt.json").files["catalog.json"] !==
            menu.catalogSha256
        )
          throw Error("Showcase catalog mismatch");
        const trained = JSON.parse(bytes);
        const ids = new Set(clips.map((c) => c.index));
        for (const c of menu.clips) {
          if (
            ids.has(c.index) ||
            !Number.isSafeInteger(c.index) ||
            !Number.isSafeInteger(c.frames) ||
            c.frames < 2 ||
            c.frames * 608 > MAX_CLIP_BYTES ||
            !/^[0-9a-f]{64}$/.test(c.source) ||
            (c.index >= 0 &&
              (trained.motion_names[c.index] !== c.name ||
                trained.motion_sha256[c.index] !== c.source ||
                c.fps !== 120)) ||
            (c.index < 0 && c.fps !== 30)
          )
            throw Error("Invalid showcase identity");
          const key = hash(
            "moonrobo.motion-shard.f64le.v1:" + c.source + ":" + c.fps,
          );
          const rel =
            "source/showcase-clips/" + key.slice(0, 2) + "/" + key + ".f64";
          const meta = read(rel + ".json");
          if (
            meta.format !== "moonrobo.motion-shard.f64le.v1" ||
            meta.source_sha256 !== c.source ||
            meta.source_fps !== c.fps ||
            meta.frames !== c.frames ||
            meta.state_sha256 !== c.sha256 ||
            fs.statSync(path.join(root, rel)).size !== c.frames * 608
          )
            throw Error("Unmatched showcase reference");
          const url = "clips/" + c.index + ".f64";
          files.set(url, rel);
          ids.add(c.index);
          clips.push({
            index: c.index,
            name: c.name,
            label: c.label,
            group: c.group,
            frames: c.frames,
            sha256: c.sha256,
            url,
          });
        }
      }
      return { meshes, clips, sceneSha256: hash(scene) };
    }
    server.middlewares.use("/g1-data", (req, res) => {
      res.setHeader("Cache-Control", "no-store");
      res.setHeader("X-Content-Type-Options", "nosniff");
      const stop = (n, msg) => {
        res.statusCode = n;
        res.end(msg);
      };
      if (
        !root ||
        !["127.0.0.1", "::1", "::ffff:127.0.0.1"].includes(
          req.socket.remoteAddress,
        )
      )
        return stop(404, "Local G1 bundle is unavailable");
      if (req.method !== "GET" && req.method !== "HEAD")
        return stop(405, "Read only");
      try {
        manifest ||= index();
        const key = new URL(req.url, "http://localhost").pathname.slice(1);
        if (key === "manifest.json") {
          res.setHeader("Content-Type", "application/json");
          return res.end(
            req.method === "HEAD" ? undefined : JSON.stringify(manifest),
          );
        }
        if (!files.has(key)) return stop(404, "Asset unavailable");
        const file = path.join(root, files.get(key)),
          stat = fs.statSync(file);
        res.setHeader(
          "Content-Type",
          key.endsWith(".json")
            ? "application/json"
            : key.endsWith(".xml")
              ? "application/xml"
              : "application/octet-stream",
        );
        res.setHeader("Content-Length", stat.size);
        if (req.method === "HEAD") return res.end();
        const stream = fs.createReadStream(file);
        stream.on("error", () => res.destroy());
        res.on("close", () => stream.destroy());
        stream.pipe(res);
      } catch {
        return stop(
          503,
          "The local checkpoint or motion bundle is incomplete.",
        );
      }
    });
  }
  return {
    name: "moonrobo-local-g1",
    configureServer: attach,
    configurePreviewServer: attach,
  };
}
