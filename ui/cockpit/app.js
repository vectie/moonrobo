const sampleSnapshot = {
  robot: {
    root: "examples/noetix-e1",
    robot_id: "noetix-e1-lab-01",
    label: "Noetix E1 Lab 01",
    platform: "noetix-e1",
    model_primary: "model/robot.urdf",
    ready: true,
    missing_paths: 0,
    validation_issues: 0,
    joints: 24,
    sensors: 2,
    capabilities: 3,
  },
  bridge: {
    bridge_id: "sdk-e1",
    status: "ok",
    mode: "read-only",
    telemetry_age_ms: 0,
    telemetry_stale: false,
  },
  telemetry: {
    frame_id: "mock-0",
    captured_at_ms: "0",
    mode: "read-only",
    joints: 24,
    imu_available: true,
    operator_input_fields: 1,
    errors: 0,
  },
  safety: {
    intent_id: "intent-cli-cockpit-walk",
    capability: "control.high.walk",
    decision: "dry-run-required",
    reason: "dry-run-missing",
    next_action: "collect-dry-run",
    detail: "capability `control.high.walk` requires a dry-run receipt",
  },
  receipt_count: 1,
  latest_receipt: {
    receipt_id: "receipt-cli-plan-walk",
    status: "waiting-for-dry-run",
    capability: "control.high.walk",
    started_at_ms: "0",
  },
  read_only: true,
};

const byId = (id) => document.getElementById(id);

function text(id, value) {
  byId(id).textContent = value === undefined || value === null || value === "" ? "-" : String(value);
}

function setBadge(id, label, tone) {
  const node = byId(id);
  node.textContent = label || "unknown";
  node.className = `badge ${tone || "neutral"}`;
}

function toneForStatus(status) {
  if (status === "ok" || status === "ready") return "ok";
  if (status === "stale" || status === "dry-run-required" || status === "waiting-for-dry-run") {
    return "warning";
  }
  if (status === "blocked" || status === "error" || status === "not-ready") return "danger";
  return "neutral";
}

function metric(label, value) {
  const item = document.createElement("div");
  item.className = "metric";
  const labelNode = document.createElement("span");
  labelNode.textContent = label;
  const valueNode = document.createElement("strong");
  valueNode.textContent = value === undefined || value === null ? "-" : String(value);
  item.append(labelNode, valueNode);
  return item;
}

function renderMetrics(id, items) {
  const root = byId(id);
  root.replaceChildren(...items.map(([label, value]) => metric(label, value)));
}

function renderJointStrip(count) {
  const root = byId("joint-strip");
  const total = Number.isFinite(count) && count > 0 ? count : 0;
  const nodes = Array.from({ length: total }, (_, index) => {
    const cell = document.createElement("div");
    cell.className = "joint-cell";
    cell.textContent = `J${index + 1}`;
    return cell;
  });
  root.replaceChildren(...nodes);
}

function renderSnapshot(snapshot) {
  const robot = snapshot.robot || {};
  const bridge = snapshot.bridge || {};
  const telemetry = snapshot.telemetry || {};
  const safety = snapshot.safety || {};
  const latestReceipt = snapshot.latest_receipt || {};
  const readyLabel = robot.ready ? "ready" : "not-ready";

  text("robot-title", robot.label);
  text("robot-id", robot.robot_id);
  text("platform", robot.platform);
  text("model-primary", robot.model_primary);
  text("robot-root", robot.root);
  setBadge("ready-badge", readyLabel, toneForStatus(readyLabel));
  setBadge("read-only-badge", snapshot.read_only ? "read-only" : "control", snapshot.read_only ? "accent" : "warning");
  renderMetrics("robot-metrics", [
    ["Joints", robot.joints],
    ["Sensors", robot.sensors],
    ["Caps", robot.capabilities],
  ]);
  renderJointStrip(Number(robot.joints || telemetry.joints || 0));

  text("bridge-id", bridge.bridge_id);
  text("bridge-mode", bridge.mode);
  text("telemetry-age", `${bridge.telemetry_age_ms ?? "-"} ms`);
  setBadge("bridge-status", bridge.status || "unknown", toneForStatus(bridge.status));
  const freshness = byId("freshness");
  freshness.textContent = bridge.telemetry_stale ? "Telemetry stale" : "Telemetry fresh";
  freshness.className = `freshness ${bridge.telemetry_stale ? "warning" : "ok"}`;

  setBadge("safety-decision", safety.decision || "pending", toneForStatus(safety.decision));
  text("capability", safety.capability);
  text("next-action", safety.next_action);
  text("safety-reason", safety.reason);
  text("safety-detail", safety.detail);

  setBadge("telemetry-mode", telemetry.mode || "unknown", toneForStatus(telemetry.errors > 0 ? "error" : "ok"));
  renderMetrics("telemetry-metrics", [
    ["Frame", telemetry.frame_id],
    ["Captured", telemetry.captured_at_ms],
    ["Errors", telemetry.errors],
    ["IMU", telemetry.imu_available ? "yes" : "no"],
    ["Operator", telemetry.operator_input_fields],
    ["Joints", telemetry.joints],
  ]);

  setBadge("receipt-count", `${snapshot.receipt_count || 0} receipts`, "neutral");
  text("receipt-id", latestReceipt.receipt_id);
  text("receipt-status", latestReceipt.status);
  text("receipt-capability", latestReceipt.capability);
  text("receipt-started", latestReceipt.started_at_ms);
}

async function loadSample() {
  try {
    const response = await fetch("./sample-cockpit.json", { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    renderSnapshot(await response.json());
  } catch {
    renderSnapshot(sampleSnapshot);
  }
}

function bindImport() {
  byId("snapshot-file").addEventListener("change", async (event) => {
    const file = event.target.files && event.target.files[0];
    if (!file) return;
    const content = await file.text();
    renderSnapshot(JSON.parse(content));
  });
  byId("reload-sample").addEventListener("click", loadSample);
}

bindImport();
loadSample();
