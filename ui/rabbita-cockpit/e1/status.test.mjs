import { test } from "node:test";
import assert from "node:assert/strict";
import { chartPoints, estimateRate, validateStatus } from "./status.js";

test("throughput uses timestamp groups and excludes world-only warm-up", () => {
  const start = Date.parse("2026-11-10T16:00:00Z");
  const points = Array.from({ length: 800 }, (_, i) => ({
    iteration: i + 1,
    at: new Date(start + (i < 499 ? Math.floor(i / 10) * 17000 : 850000 + Math.floor((i - 499) / 10) * 30000)).toISOString(),
  }));
  assert.ok(Math.abs(estimateRate(points) - 3) < .05);
  assert.equal(estimateRate(points.slice(0, 10)), null);
  assert.equal(estimateRate([]), null);
});
test("chart reduction preserves bucket means and the final iteration", () => {
  const points = Array.from({ length: 400 }, (_, i) => ({ iteration: i + 1, world_loss: i % 2 ? 2 : 0 }));
  const chart = chartPoints(points, 20);
  assert.equal(chart.length, 20);
  assert.equal(chart.at(-1).iteration, 400);
  assert.ok(chart.every((p) => p.world_loss === 1));
  assert.deepEqual(chartPoints([{ iteration: 1, world_loss: NaN }]), []);
});
test("status rejects invalid progress and dates", () => {
  const base = { format: "moonrobo.e1-showcase-status.v1", iteration: 500, target_iterations: 14000,
    observed_at: "2026-11-10T16:00:00Z", points: [], state: "running" };
  assert.equal(validateStatus(base), base);
  assert.throws(() => validateStatus({ ...base, iteration: 14001 }));
  assert.throws(() => validateStatus({ ...base, observed_at: "unavailable" }));
  assert.throws(() => validateStatus({ ...base, state: "imagined" }));
});
