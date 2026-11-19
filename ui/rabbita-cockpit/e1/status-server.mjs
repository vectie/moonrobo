// Optional read-only bridge for local previews. Public builds use the dated
// snapshot; credentials, SSH topology and training archives never enter dist.
import { execFile } from "node:child_process";
import { promisify } from "node:util";
const exec = promisify(execFile);
export function e1TrainingStatus(options = {}) {
  let cache, pending;
  const host = process.env.MOONROBO_E1_SSH_HOST || options.host;
  const socket = process.env.MOONROBO_E1_SSH_SOCKET || options.socket;
  function attach(server) {
    server.middlewares.use("/__e1/status", async (req, res) => {
      res.setHeader("Cache-Control", "no-store");
      res.setHeader("Content-Type", "application/json; charset=utf-8");
      if (!host || host !== "wlc004s@192.168.2.179" || !socket) {
        res.statusCode = 503;
        return res.end(JSON.stringify({ error: "Live bridge not configured" }));
      }
      if (!pending && (!cache || Date.now() - cache.at > 30000)) {
        pending = exec("ssh", ["-S", socket, "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
          "-J", "lunanexa-access", host,
          "MOON_HOME=/home/wlc004s/moonrobo/toolchain PATH=/home/wlc004s/moonrobo/toolchain/bin:/usr/bin:/bin moon run /home/wlc004s/moonrobo/private/e1-native-20261110/e1_showcase_status.mbtx"],
        { timeout: 20000, maxBuffer: 3 * 1024 * 1024 }).then(({ stdout }) => {
          const data = JSON.parse(stdout);
          if (data.format !== "moonrobo.e1-showcase-status.v1" || !Number.isInteger(data.iteration))
            throw Error("Invalid Spark status");
          cache = { at: Date.now(), data };
        }).finally(() => { pending = null; });
      }
      try {
        if (pending) await pending;
        res.end(JSON.stringify({ ...cache.data, delivery: "live" }));
      } catch {
        res.statusCode = 503;
        res.end(JSON.stringify({ error: "Spark status unavailable" }));
      }
    });
  }
  return { name: "e1-training-status", configureServer: attach, configurePreviewServer: attach };
}
