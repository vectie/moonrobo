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
  assert_eq(plan.classification, "observation")
  assert_eq(plan.suggested_capability, "observe.telemetry")
  assert_true(!plan.physical_execution_allowed)
  assert_true(!plan.requires_review)
  assert_true(plan.intent_draft is None)
}

///|
test "task message maps physical action requests to command review" {
  let request = @task.task_message_request(
    "operator-002",
    "",
    @core.operator_requester("rabbita"),
    "walk forward",
    5000L,
  )
  let plan = @task.plan_task_message(profile(), request).unwrap()
  assert_true(plan.task.kind is ReviewCommandIntent)
  assert_eq(plan.route, "/api/intents/evaluate")
  assert_eq(plan.classification, "command-intent-review")
  assert_eq(plan.suggested_capability, "control.high.walk")
  assert_true(!plan.physical_execution_allowed)
  assert_true(plan.requires_review)
  match plan.intent_draft {
    Some(draft) => {
      assert_eq(draft.intent_id, "intent-message-operator-002")
      assert_eq(draft.receipt_id, "receipt-message-operator-002-review")
      assert_eq(draft.capability, "control.high.walk")
      assert_eq(draft.parameters.get("x").unwrap(), "0.10")
      assert_eq(draft.parameters.get("duration_ms").unwrap(), "1000")
      assert_true(!draft.developer_gate)
    }
    None => fail("expected command-review task message to include intent draft")
  }
}

///|
test "task message maps simulation requests without physical authority" {
  let simulated = {
    ..profile(),
    bridge: {
      id: "sim",
      kind: @core.BridgeKind::Sim,
      config_path: "bridge/sim.json",
    },
    capabilities: [
      @core.capability(
        "simulate.motion",
        @core.CommandClass::Simulate,
        "Simulate bounded motion",
      ),
    ],
    limits: { ..profile().limits, default_mode: "simulation-only" },
  }
  let request = @task.task_message_request(
    "operator-sim",
    "",
    @core.operator_requester("rabbita"),
    "simulate the bounded route",
    5000L,
  )
  let plan = @task.plan_task_message(simulated, request).unwrap()
  assert_eq(plan.classification, "simulation-intent")
  assert_eq(plan.suggested_capability, "simulate.motion")
  assert_true(!plan.physical_execution_allowed)
  assert_true(!plan.requires_review)
  assert_true(plan.intent_draft is Some(_))
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

///|
test "task message maps maintenance requests to review queue" {
  let request = @task.task_message_request(
    "operator-004",
    "",
    @core.operator_requester("rabbita"),
    "check battery and schedule maintenance",
    5000L,
  )
  let plan = @task.plan_task_message(profile(), request).unwrap()
  assert_true(plan.task.kind is ReviewMaintenance)
  assert_eq(plan.route, "/api/moonrobo/platform-queue")
  assert_eq(plan.classification, "maintenance-review")
  assert_true(!plan.physical_execution_allowed)
  assert_true(plan.requires_review)
  assert_true(plan.intent_draft is None)
}

///|
test "task message treats diagnostics as maintenance review before motion" {
  let request = @task.task_message_request(
    "operator-005",
    "",
    @core.operator_requester("rabbita"),
    "run diagnostic on the robot fault",
    5000L,
  )
  let plan = @task.plan_task_message(profile(), request).unwrap()
  assert_true(plan.task.kind is ReviewMaintenance)
  assert_eq(plan.classification, "maintenance-review")
  assert_eq(plan.route, "/api/moonrobo/platform-queue")
}
