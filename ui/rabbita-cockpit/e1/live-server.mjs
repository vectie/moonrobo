import { readFile, stat } from "node:fs/promises";
import { dirname, join } from "node:path";

// The relay atomically replaces one private file on arrival of a new DDS sample.
export function e1LivePose(path, replayPath, policyPath) {
  const install = server => {
    function route(url, read) {
      server.middlewares.use(url, async (req, res) => {
        res.setHeader("Cache-Control", "no-store");
        res.setHeader("Content-Type", "application/json");
        res.setHeader("Cross-Origin-Resource-Policy", "same-origin");
        const local = ["127.0.0.1","::1","::ffff:127.0.0.1"].includes(req.socket.remoteAddress);
        const site = req.headers["sec-fetch-site"];
        if (req.method !== "GET" || !local || (site && !["same-origin","none"].includes(site))) {
          res.statusCode = 403; return res.end("{}");
        }
        try {
          return res.end(await read());
        } catch {
          res.statusCode = 503; return res.end('{"live":false}');
        }
      });
    }
    route("/__e1_pose", async () => {
      if (!path) throw Error();
      if (Date.now() - (await stat(path)).mtimeMs > 1200) throw Error();
      return readFile(path, "utf8");
    });
    route("/__e1_shadow", () => readFile(join(dirname(path), "shadow-poses.json"), "utf8"));
    route("/__e1_replay", () => readFile(replayPath, "utf8"));
    route("/__e1_policy", () => readFile(policyPath, "utf8"));
  };
  return {name:"read-only-e1-pose",configureServer:install,configurePreviewServer:install};
}
