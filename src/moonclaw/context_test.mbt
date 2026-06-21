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
    capability_count: 1,
    review_count,
    command_path: "/tmp/moonclaw-test-sidecar",
    town_route: "/town/residents/robot:moonclaw-test",
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
  }
}

///|
test "moonclaw plans review before new work" {
  let result = @moonclaw.planning_result(
    resident_with(None, 1),
    [process_review(NeedsHumanReview)],
    2000L,
  )
  assert_true(result.plan.action == ReviewEvidence)
  assert_eq(result.context.needs_human_count, 1)
  assert_true(result.plan.evidence_paths.contains("/tmp/review-artifact.json"))
}

///|
test "moonclaw respects resident receipt review state" {
  let result = @moonclaw.planning_result(resident_with(None, 1), [], 2000L)
  assert_true(result.plan.action == ReviewEvidence)
  assert_eq(result.context.review_count, 1)
  assert_true(result.plan.steps[0].route.contains("resident"))
}

///|
test "moonclaw plans observation when clear" {
  let result = @moonclaw.planning_result(resident_with(None, 0), [], 2000L)
  assert_true(result.plan.action == Observe)
  assert_true(result.plan.steps[0].route.contains("observe-run"))
}

///|
test "moonclaw holds while observation is active" {
  let result = @moonclaw.planning_result(
    resident_with(Some(active_summary()), 0),
    [process_review(Accepted)],
    2000L,
  )
  assert_true(result.plan.action == Hold)
  assert_true(result.plan.summary.contains("already observing"))
}
