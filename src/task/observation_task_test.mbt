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

///|
test "task message compiles to read-only observation task" {
  let request = @task.task_message_request(
    "operator-001",
    "",
    @core.operator_requester("rabbita"),
    "Inspect the desk area and report status",
    5000L,
  )
  let plan = @task.plan_task_message(profile(), request).unwrap()
  assert_eq(plan.task.task_id, "message-operator-001")
  assert_eq(plan.task.goal, "Inspect the desk area and report status")
  assert_eq(plan.route, "/api/moontown/tasks/observe")
  assert_eq(plan.reason, "message mapped to read-only observation task")
}

///|
test "task message rejects physical action requests" {
  let request = @task.task_message_request(
    "operator-002",
    "",
    @core.operator_requester("rabbita"),
    "walk forward",
    5000L,
  )
  match @task.plan_task_message(profile(), request) {
    Err(issue) => assert_eq(issue.code, "physical-action-message")
    Ok(_) => fail("expected task message planner to reject physical action")
  }
}

///|
test "task message classifies words without substring action false positives" {
  let request = @task.task_message_request(
    "operator-003",
    "",
    @core.operator_requester("rabbita"),
    "Help me understand status.",
    5000L,
  )
  let plan = @task.plan_task_message(profile(), request).unwrap()
  assert_eq(plan.task.task_id, "message-operator-003")
  assert_eq(plan.task.goal, "Help me understand status.")
}
