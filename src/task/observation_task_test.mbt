///|
fn profile() -> @core.RobotProfile {
  @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
}

///|
test "observation task compiles to session and receipt ids" {
  let request = @task.observe_task_request(
    "standing-goal-001",
    "noetix-e1-lab-01",
    @core.moontown_requester("standing-goal"),
    "scheduled telemetry check",
    3000L,
  )
  let plan = @task.plan_observation_task(profile(), request).unwrap()
  assert_true(plan.status == Planned)
  assert_eq(plan.capability, "observe.telemetry")
  assert_eq(plan.session_id, "task-standing-goal-001-observe")
  assert_eq(plan.receipt_id, "receipt-standing-goal-001-observe")
  assert_eq(plan.requester.kind, "moontown")
}

///|
test "observation task rejects robot mismatch" {
  let request = @task.observe_task_request(
    "standing-goal-002",
    "other-robot",
    @core.moontown_requester("standing-goal"),
    "scheduled telemetry check",
    3000L,
  )
  match @task.plan_observation_task(profile(), request) {
    Err(issue) => assert_eq(issue.code, "robot-mismatch")
    Ok(_) => fail("expected task planning to reject robot mismatch")
  }
}
