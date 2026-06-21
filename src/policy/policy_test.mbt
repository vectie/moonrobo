///|
fn walk_proposal() -> @policy.PolicyProposal {
  {
    proposal_id: "proposal-policy-walk",
    policy_id: "policy-offline-walk",
    episode_id: "episode-task-dataset",
    robot_id: "noetix-e1-lab-01",
    capability: "control.high.walk",
    parameters: { "x": "0.10", "yaw": "0.00", "duration_ms": "1000" },
    confidence: 0.84,
    created_at_ms: 1000L,
  }
}

///|
test "policy proposal becomes command intent but never physical execution" {
  let profile = @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
  let evaluation = @policy.evaluate_proposal(
    profile,
    @core.bridge_ok("sdk-e1", profile.id, last_telemetry_age_ms=10),
    walk_proposal(),
    "policy-eval-walk",
    "receipt-policy-walk",
    1100L,
    None,
  )
  assert_eq(evaluation.intent.intent_id, "intent-proposal-policy-walk")
  assert_eq(evaluation.intent.requested_by.kind, "policy")
  assert_true(evaluation.result.next_action == CollectDryRun)
  assert_eq(evaluation.gate_status, "requires-dry-run")
  assert_true(!evaluation.physical_execution_allowed)
}

///|
test "policy gate blocks proposals from failed dataset quality" {
  let profile = @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
  let quality : @dataset.DatasetQualityReport = {
    episode_id: "episode-task-dataset",
    passed: false,
    issue_count: 1,
    blocker_count: 1,
    warning_count: 0,
    frame_count: 0,
    artifact_count: 0,
    issues: [
      {
        code: "too-few-frames",
        severity: "blocker",
        message: "episode has fewer than 1 frame(s)",
      },
    ],
  }
  let evaluation = @policy.evaluate_proposal(
    profile,
    @core.bridge_ok("sdk-e1", profile.id, last_telemetry_age_ms=10),
    walk_proposal(),
    "policy-eval-quality",
    "receipt-policy-quality",
    1200L,
    Some(quality),
  )
  assert_eq(evaluation.gate_status, "blocked-quality")
  assert_true(!evaluation.physical_execution_allowed)
  assert_true(evaluation.quality_report is Some(_))
}
