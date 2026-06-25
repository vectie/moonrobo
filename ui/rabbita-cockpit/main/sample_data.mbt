///|
fn sample_snapshot() -> @cockpit.CockpitSnapshot {
  {
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
    product_status: {
      service: "moonrobo",
      root: "examples/noetix-e1",
      status: "needs-foundation",
      ready: false,
      percent: 33,
      completed_count: 2,
      total_count: 6,
      robot_id: "noetix-e1-lab-01",
      bridge_id: "sdk-e1",
      next_route: "/api/moonrobo/ask",
      capabilities: [
        {
          code: "digital-physical-map",
          label: "One RoboBook profile maps to one resident robot body",
          ready: true,
          evidence_path: "/api/moontown/resident",
          next_route: "/api/moonrobo/readiness",
          message: "RoboBook identity is mapped to the resident robot.",
        },
        {
          code: "user-task-message",
          label: "User can ask Robo to do a task",
          ready: false,
          evidence_path: "/api/moonbook/task-messages",
          next_route: "/api/moonrobo/ask",
          message: "Ask Robo so the task, memory, loop proof, readiness, and decision stay in one response.",
        },
      ],
      message: "Moonrobo still needs foundation evidence; continue with /api/moonrobo/ask.",
    },
    bridge: {
      bridge_id: "sdk-e1",
      status: "ok",
      mode: "read-only",
      telemetry_age_ms: Some(0),
      telemetry_stale: false,
    },
    sidecar: {
      sidecar_id: "noetix-e1-lab-01:sdk-e1",
      state: "missing-command",
      command_path: "moonrobo-sdk-e1-bridge",
      command_available: false,
      health_path: "/health",
      execute_path: "/intents/execute",
      ready_for_execution: false,
      detail: "bridge sidecar command is missing: moonrobo-sdk-e1-bridge",
    },
    telemetry: {
      frame_id: "mock-0",
      captured_at_ms: 0L,
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
    latest_receipt: Some({
      receipt_id: "receipt-cli-plan-walk",
      status: "waiting-for-dry-run",
      capability: "control.high.walk",
      started_at_ms: 0L,
      bridge_error: None,
    }),
    read_only: true,
  }
}

///|
fn sample_moonstat_status() -> @moonstat.MoonroboStatus {
  {
    service: "moonrobo",
    robobook_root: "examples/noetix-e1",
    robot_id: "noetix-e1-lab-01",
    ready: true,
    status: "degraded",
    bridge_state: "missing-command",
    availability: "idle",
    safety_state: "waiting-for-dry-run",
    receipt_count: 1,
    observation_count: 0,
    process_review_count: 0,
    policy_evaluation_count: 0,
    pending_review_count: 0,
    agent_process_run_count: 0,
    latest_run_id: "-",
    latest_session_id: "-",
    latest_review_id: "-",
    latest_policy_evaluation_id: "-",
    latest_policy_gate_status: "-",
    latest_policy_path: "-",
    latest_replay_path: "-",
    latest_evidence_path: "-",
    generated_at_ms: 0L,
  }
}

///|
fn sample_runtime_supervisor_status() -> RuntimeSupervisorStatus {
  {
    status: "collector-ready",
    ready: true,
    snapshot_ready: false,
    bridge_base_url: "http://127.0.0.1:5391",
    processes: [
      {
        process_id: "noetix-e1-lab-01:sdk-e1:collector",
        state: "ReadyToStart",
        command_available: true,
      },
      {
        process_id: "noetix-e1-lab-01:sdk-e1:bridge",
        state: "WaitingForSnapshot",
        command_available: true,
      },
    ],
    issues: [],
  }
}

fn sample_work_item() -> @work_queue.AgentWorkItem {
  {
    work_id: "work-noetix-e1-lab-01-start-runtime",
    kind: "start-runtime",
    priority: 100,
    title: "Start supervised runtime",
    summary: "Robot resident needs its supervised runtime before bridge validation",
    target_id: "noetix-e1-lab-01",
    target_path: "/api/runtime/supervisor/start",
    reason: "Physical-world agents need supervised runtime health before bridge validation, observation, or command work",
  }
}

///|
fn sample_work_queue() -> @work_queue.AgentWorkQueue {
  let item = sample_work_item()
  {
    queue_id: "work-queue-noetix-e1-lab-01-0",
    robot_id: "noetix-e1-lab-01",
    resident_id: "robot:noetix-e1-lab-01",
    generated_at_ms: 0L,
    item_count: 1,
    high_priority_count: 1,
    next_item: Some(item),
    items: [item],
  }
}

///|
fn sample_next_action() -> @work_queue.AgentNextAction? {
  Some(@work_queue.action_for_item(sample_work_item()))
}
