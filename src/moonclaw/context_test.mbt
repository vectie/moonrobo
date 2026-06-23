///|
fn resident_with(
  active_observation : @resident.ResidentObservationSummary?,
  review_count : Int,
) -> @resident.ResidentRobotAgent {
  {
    resident_id: "robot:moonclaw-test",
    robot_id: "moonclaw-test",
    label: "MoonClaw Test Robot",
    platform: "test",
    role: "physical-robot",
    availability: if active_observation is Some(_) {
      "observing"
    } else {
      "ready"
    },
    safety_state: if review_count > 0 {
      "review-required"
    } else {
      "clear"
    },
    bridge_state: "launchable",
    active_observation,
    latest_observation: active_observation,
    latest_receipt: None,
    latest_execution: None,
    execution_count: 0,
    verified_execution_count: 0,
    capability_count: 1,
    review_count,
    command_path: "/tmp/moonclaw-test-sidecar",
    town_route: "/town/residents/robot:moonclaw-test",
  }
}

///|
fn unverified_execution() -> @resident.ResidentExecutionSummary {
  {
    snapshot_id: "task-execution-moonclaw-test",
    task_id: "message-moonclaw-test",
    status: "bridge-accepted",
    verified: false,
    message: "execution needs runtime proof",
    receipt_id: "receipt-moonclaw-test-executed",
    command_capability: "control.high.walk",
    bridge_status: "Accepted",
    runtime_status: "",
    runtime_health_persisted: false,
    telemetry_frame_id: "",
    physical_feedback_path: "",
    physical_feedback_status: "missing",
    physical_feedback_verified: false,
    command_outcome_status: "unconfirmed",
    command_outcome_verified: false,
    captured_at_ms: 1002L,
  }
}

///|
fn active_summary() -> @resident.ResidentObservationSummary {
  {
    session_id: "observe-moonclaw-test",
    status: "active",
    telemetry_frame_count: 1,
    latest_frame_id: Some("frame-moonclaw-test"),
    latest_artifact_path: Some("/tmp/frame-moonclaw-test.json"),
    started_at_ms: 1000L,
    stopped_at_ms: None,
  }
}

///|
fn process_review(
  disposition : @review.ReviewDisposition,
) -> @review.ProcessReview {
  {
    review_id: "review-moonclaw-test",
    task_id: "task-moonclaw-test",
    session_id: "observe-moonclaw-test",
    robot_id: "moonclaw-test",
    receipt_id: "receipt-moonclaw-test",
    disposition,
    severity: if disposition == NeedsHumanReview {
      Attention
    } else {
      Info
    },
    summary: "review summary",
    findings: if disposition == NeedsHumanReview {
      ["finding"]
    } else {
      []
    },
    artifact_paths: ["/tmp/review-artifact.json"],
    created_at_ms: 1001L,
    resolved_at_ms: None,
    resolution_note: None,
  }
}

///|
fn memory_for(
  resident : @resident.ResidentRobotAgent,
) -> @moonbook.MoonBookMemoryPack {
  {
    pack_id: "moonbook-memory-\{resident.robot_id}-2000",
    robot_id: resident.robot_id,
    resident_id: resident.resident_id,
    generated_at_ms: 2000L,
    card_count: 1,
    highest_priority: 65,
    cards: [
      {
        memory_id: "memory-\{resident.robot_id}-latest-observation-2000",
        robot_id: resident.robot_id,
        resident_id: resident.resident_id,
        kind: "latest-observation",
        priority: 65,
        title: "Latest observation",
        summary: "remembered observation",
        evidence_path: "/api/replays/remembered-session",
        next_route: "/api/replays/remembered-session",
        created_at_ms: 2000L,
      },
    ],
  }
}

///|
fn registry_for(
  resident : @resident.ResidentRobotAgent,
) -> @tool_registry.ToolRegistry {
  @tool_registry.default_registry(resident.robot_id, 2000L)
}

///|
fn planning_for(
  resident : @resident.ResidentRobotAgent,
  reviews : Array[@review.ProcessReview],
) -> @moonclaw.MoonClawPlanningResult {
  @moonclaw.planning_result(
    resident,
    reviews,
    memory_for(resident),
    registry_for(resident),
    2000L,
  )
}

///|
test "moonclaw inspects unverified execution before new work" {
  let result = planning_for(
    {
      ..resident_with(None, 0),
      latest_execution: Some(unverified_execution()),
      execution_count: 1,
      verified_execution_count: 0,
    },
    [],
  )
  assert_true(result.plan.action == ReviewEvidence)
  assert_true(result.plan.summary.contains("execution proof"))
  assert_eq(result.plan.steps[0].route, "/api/moonrobo/executions")
  assert_true(result.plan.evidence_paths.contains("/api/moonrobo/executions"))
}

///|
test "moonclaw plans review before new work" {
  let result = planning_for(resident_with(None, 1), [
    process_review(NeedsHumanReview),
  ])
  assert_true(result.plan.action == ReviewEvidence)
  assert_eq(result.context.needs_human_count, 1)
  assert_true(result.plan.evidence_paths.contains("/tmp/review-artifact.json"))
  assert_eq(result.context.memory.card_count, 1)
  assert_true(result.context.tool_registry.capability_count >= 12)
}

///|
test "moonclaw respects resident receipt review state" {
  let result = planning_for(resident_with(None, 1), [])
  assert_true(result.plan.action == ReviewEvidence)
  assert_eq(result.context.review_count, 1)
  assert_true(result.plan.steps[0].route.contains("resident"))
  assert_true(
    result.plan.evidence_paths.contains("/api/replays/remembered-session"),
  )
}

///|
test "moonclaw plans observation when clear" {
  let result = planning_for(resident_with(None, 0), [])
  assert_true(result.plan.action == Observe)
  assert_true(result.plan.steps[0].route.contains("observe-run"))
  assert_true(result.plan.steps[0].reason.contains("registered tool"))
}

///|
test "moonclaw holds while observation is active" {
  let result = planning_for(resident_with(Some(active_summary()), 0), [
    process_review(Accepted),
  ])
  assert_true(result.plan.action == Hold)
  assert_true(result.plan.summary.contains("already observing"))
}
