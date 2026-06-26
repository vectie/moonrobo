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
    latest_proof_session: None,
    execution_count: 0,
    verified_execution_count: 0,
    proof_session_count: 0,
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
fn blocked_proof_session() -> @resident.ResidentProofSessionSummary {
  @resident.proof_session_summary(
    "proof-session-moonclaw-test", "blocked", false, 2, 3, "stalled", "/runs/proof-sessions/proof-session-moonclaw-test.json",
    "/runs/prove-loop/prove-loop-moonclaw-test.json", "/api/runtime/supervisor/start",
    0, 0, false, 0, "", "Moonrobo proof session stopped without new progress; continue with /api/runtime/supervisor/start.",
  )
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
fn ready_report(
  resident : @resident.ResidentRobotAgent,
) -> @readiness.PlatformReadinessReport {
  {
    report_id: "moonrobo-readiness-\{resident.robot_id}",
    root: "/tmp/moonclaw-readiness",
    robot_id: resident.robot_id,
    ready: true,
    status: "ready",
    check_count: 0,
    pass_count: 0,
    fail_count: 0,
    conversation_turn_count: 0,
    memory_card_count: 0,
    registered_capability_count: resident.capability_count,
    task_execution_count: resident.execution_count,
    latest_runtime_status: "healthy",
    checks: [],
  }
}

///|
fn readiness_blocked_report(
  resident : @resident.ResidentRobotAgent,
) -> @readiness.PlatformReadinessReport {
  let check : @readiness.ReadinessCheck = {
    code: "runtime-validation-current",
    status: "fail",
    path: "runs/runtime-validation/latest-session.json",
    message: "runtime calibration was resolved but needs a newer validation session before dispatch",
  }
  {
    ..ready_report(resident),
    ready: false,
    status: "blocked",
    check_count: 1,
    fail_count: 1,
    latest_runtime_status: "healthy",
    checks: [check],
  }
}

///|
fn readiness_plan_for(
  report : @readiness.PlatformReadinessReport,
) -> @readiness.PlatformReadinessPlan {
  @readiness.plan(report)
}

///|
fn gateway_for(
  resident : @resident.ResidentRobotAgent,
) -> @gateway.MoonroboGatewayStatus {
  @gateway.project({
    root: "/tmp/moonclaw-readiness",
    robot_id: resident.robot_id,
    bridge_id: "sdk-e1",
    mapped: true,
    has_task_message: false,
    session_stage: "no-task",
    memory_card_count: 1,
    loop_ready: false,
    loop_percent: 33,
    loop_status: "incomplete",
    live_readiness_status: "needs-runtime-validation",
    physical_execution_allowed: false,
    can_submit_gateway_command: false,
    latest_task_execution_path: "",
    latest_gateway_command_path: "",
    latest_robo_loop_path: "",
    latest_proof_session_path: "",
    proof_session_feedback_closed: false,
    proof_session_auto_feedback_success_count: 0,
    proof_session_latest_feedback_status: 0,
    proof_session_latest_feedback_message: "",
    next_method: "POST",
    next_route: "/api/runtime/validation/session",
    next_title: "Collect runtime validation",
  })
}

///|
fn ready_gateway_for(
  resident : @resident.ResidentRobotAgent,
) -> @gateway.MoonroboGatewayStatus {
  @gateway.project({
    root: "/tmp/moonclaw-readiness",
    robot_id: resident.robot_id,
    bridge_id: "sdk-e1",
    mapped: true,
    has_task_message: true,
    session_stage: "ready-to-prove",
    memory_card_count: 2,
    loop_ready: false,
    loop_percent: 67,
    loop_status: "operational-unproven",
    live_readiness_status: "ready-for-proof-session",
    physical_execution_allowed: false,
    can_submit_gateway_command: true,
    latest_task_execution_path: "",
    latest_gateway_command_path: "",
    latest_robo_loop_path: "/runs/robo-loops/latest.json",
    latest_proof_session_path: "",
    proof_session_feedback_closed: false,
    proof_session_auto_feedback_success_count: 0,
    proof_session_latest_feedback_status: 0,
    proof_session_latest_feedback_message: "",
    next_method: "POST",
    next_route: "/api/moonrobo/proof-session",
    next_title: "Run bounded proof session",
  })
}

///|
fn context_for(
  resident : @resident.ResidentRobotAgent,
  reviews : Array[@review.ProcessReview],
) -> @moonclaw.MoonClawContextPack {
  let readiness = ready_report(resident)
  @moonclaw.context_pack(
    resident,
    reviews,
    memory_for(resident),
    registry_for(resident),
    readiness,
    readiness_plan_for(readiness),
    gateway_for(resident),
    2000L,
  )
}

///|
fn readiness_context_for(
  resident : @resident.ResidentRobotAgent,
) -> @moonclaw.MoonClawContextPack {
  let readiness = readiness_blocked_report(resident)
  @moonclaw.context_pack(
    resident,
    [],
    memory_for(resident),
    registry_for(resident),
    readiness,
    readiness_plan_for(readiness),
    gateway_for(resident),
    2000L,
  )
}

///|
test "moonclaw context exposes unverified execution evidence" {
  let context = context_for(
    {
      ..resident_with(None, 0),
      latest_execution: Some(unverified_execution()),
      execution_count: 1,
      verified_execution_count: 0,
    },
    [],
  )
  assert_eq(context.resident.execution_count, 1)
  assert_eq(context.resident.verified_execution_count, 0)
  assert_true(context.resident.latest_execution is Some(_))
  assert_eq(context.gateway.status, "mapped-needs-evidence")
  assert_true(context.memory.card_count > 0)
}

///|
test "moonclaw context exposes runtime readiness blockers" {
  let context = readiness_context_for(resident_with(None, 0))
  assert_true(!context.readiness.ready)
  assert_eq(context.readiness.status, "blocked")
  assert_eq(
    context.readiness.checks[0].path,
    "runs/runtime-validation/latest-session.json",
  )
  assert_eq(context.gateway.next_route, "/api/runtime/validation/session")
}

///|
test "moonclaw context exposes gateway command readiness" {
  let resident = resident_with(None, 0)
  let readiness = ready_report(resident)
  let context = @moonclaw.context_pack(
    resident,
    [],
    memory_for(resident),
    registry_for(resident),
    readiness,
    readiness_plan_for(readiness),
    ready_gateway_for(resident),
    2000L,
  )
  assert_eq(context.gateway.status, "ready-for-command")
  assert_eq(context.gateway.next_route, "/api/moonrobo/proof-session")
  assert_true(context.gateway.can_submit_gateway_command)
  assert_true(context.tool_registry.capability_count >= 12)
}

///|
test "moonclaw context exposes review and memory evidence" {
  let context = context_for(resident_with(None, 1), [
    process_review(NeedsHumanReview),
  ])
  assert_eq(context.needs_human_count, 1)
  match context.latest_review {
    Some(review) => {
      assert_eq(review.review_id, "review-moonclaw-test")
      assert_eq(review.artifact_paths[0], "/tmp/review-artifact.json")
    }
    None => assert_true(false)
  }
  assert_eq(context.memory.card_count, 1)
  assert_eq(context.gateway.status, "mapped-needs-evidence")
  assert_true(context.tool_registry.capability_count >= 12)
}

///|
test "moonclaw context respects resident receipt review state" {
  let context = context_for(resident_with(None, 1), [])
  assert_eq(context.review_count, 1)
  assert_eq(
    context.memory.cards[0].next_route,
    "/api/replays/remembered-session",
  )
  assert_eq(context.gateway.status, "mapped-needs-evidence")
}

///|
test "moonclaw context exposes clear resident state" {
  let context = context_for(resident_with(None, 0), [])
  assert_eq(context.review_count, 0)
  assert_eq(context.needs_human_count, 0)
  assert_eq(context.resident.availability, "ready")
  assert_eq(context.tool_registry.robot_id, "moonclaw-test")
}

///|
test "moonclaw context exposes incomplete proof-session evidence" {
  let context = context_for(
    {
      ..resident_with(None, 0),
      latest_proof_session: Some(blocked_proof_session()),
      proof_session_count: 1,
    },
    [],
  )
  assert_eq(context.resident.proof_session_count, 1)
  assert_true(context.resident.latest_proof_session is Some(_))
  assert_eq(context.gateway.next_route, "/api/runtime/validation/session")
}

///|
test "moonclaw context exposes active observation state" {
  let context = context_for(resident_with(Some(active_summary()), 0), [
    process_review(Accepted),
  ])
  assert_eq(context.resident.availability, "observing")
  assert_true(context.resident.active_observation is Some(_))
  assert_true(context.latest_review is Some(_))
}
