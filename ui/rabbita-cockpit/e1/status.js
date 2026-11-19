export function estimateRate(points) {
  // Docker may flush many iterations together. Measure separated timestamp
  // groups, not adjacent log-line times. Do not mix warm-up with policy work.
  const phase = points.at(-1)?.iteration >= 500;
  const rows = points.filter((p) => (p.iteration >= 500) === phase && Number.isFinite(Date.parse(p.at)));
  const end = rows.at(-1);
  if (!end) return null;
  const start = rows.find((p) => end.iteration - p.iteration >= 100 && Date.parse(end.at) - Date.parse(p.at) >= 60000);
  return start ? (Date.parse(end.at) - Date.parse(start.at)) / (end.iteration - start.iteration) / 1000 : null;
}
export function chartPoints(points, max = 160) {
  const valid = points.filter((p) => Number.isInteger(p.iteration) && Number.isFinite(p.world_loss));
  if (valid.length <= max) return valid;
  // Bucket means retain the trend without presenting a minimum-loss envelope.
  const result = [];
  for (let i = 0; i < max; i++) {
    const chunk = valid.slice(Math.floor(i * valid.length / max), Math.floor((i + 1) * valid.length / max));
    result.push({ iteration: chunk.at(-1).iteration, world_loss: chunk.reduce((sum, p) => sum + p.world_loss, 0) / chunk.length });
  }
  return result;
}
export function validateStatus(data) {
  if (data.format !== "moonrobo.e1-showcase-status.v1" || !Number.isInteger(data.iteration) ||
      data.iteration < 0 || data.iteration > 14000 || data.target_iterations !== 14000 ||
      !Number.isFinite(Date.parse(data.observed_at)) || !Array.isArray(data.points) ||
      !["running", "completed", "stopped", "failed"].includes(data.state)) throw Error("无效训练状态");
  return data;
}
