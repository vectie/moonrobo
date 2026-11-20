import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, writeFile, utimes, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { e1LivePose } from "./live-server.mjs";

test("live endpoint serves local fresh GET only and stops serving stale telemetry", async () => {
  const dir = await mkdtemp(join(tmpdir(), "e1-live-test-"));
  try {
    const file = join(dir, "latest.json");
    await writeFile(file, '{"source_ns":"123"}');
    const routes = new Map();
    e1LivePose(file).configureServer({ middlewares: { use: (path, handler) => routes.set(path, handler) } });
    const call = async (overrides = {}) => {
      const req = { method: "GET", socket: { remoteAddress: "127.0.0.1" }, headers: {}, ...overrides };
      const res = { statusCode: 200, setHeader() {}, end(body) { this.body = body; } };
      await routes.get("/__e1_pose")(req, res);
      return res;
    };
    assert.equal((await call()).body, '{"source_ns":"123"}');
    assert.equal((await call({ method: "POST" })).statusCode, 403);
    assert.equal((await call({ socket: { remoteAddress: "192.0.2.1" } })).statusCode, 403);
    assert.equal((await call({ headers: { "sec-fetch-site": "cross-site" } })).statusCode, 403);
    const old = new Date(Date.now() - 5000);
    await utimes(file, old, old);
    assert.equal((await call()).statusCode, 503);
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test("recorded replay stays available without a live feed and only accepts local GET", async () => {
  const dir = await mkdtemp(join(tmpdir(), "e1-replay-test-"));
  try {
    const replay = join(dir, "gesture.json");
    await writeFile(replay, '{"published":false,"frames":[]}');
    const routes = new Map();
    e1LivePose(undefined, replay).configureServer({ middlewares: { use: (path, handler) => routes.set(path, handler) } });
    const call = async (path, overrides = {}) => {
      const req = { method: "GET", socket: { remoteAddress: "127.0.0.1" }, headers: {}, ...overrides };
      const res = { statusCode: 200, setHeader() {}, end(body) { this.body = body; } };
      await routes.get(path)(req, res); return res;
    };
    assert.equal((await call("/__e1_replay")).body, '{"published":false,"frames":[]}');
    assert.equal((await call("/__e1_pose")).statusCode, 503);
    assert.equal((await call("/__e1_replay", { method: "POST" })).statusCode, 403);
    assert.equal((await call("/__e1_replay", { headers: { "sec-fetch-site": "cross-site" } })).statusCode, 403);
  } finally { await rm(dir, { recursive: true, force: true }); }
});
