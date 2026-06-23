///|
fn message_plan() -> @task.RobotTaskMessagePlan {
  @task.plan_task_message(
    @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01"),
    @task.task_message_request(
      "status-test",
      "noetix-e1-lab-01",
      @core.operator_requester("moonbook-test"),
      "walk forward",
      7000L,
    ),
  ).unwrap()
}

///|
fn ready_receipt(
  plan : @task.RobotTaskMessagePlan,
  draft : @task.RobotTaskIntentDraft,
) -> @core.RunReceipt {
  let intent = @core.command_intent(
    draft.intent_id,
    plan.task.robot_id,
    draft.capability,
    plan.task.requested_by,
    parameters=draft.parameters,
  )
  @core.receipt_from_verdict(
    draft.receipt_id,
    "sdk-e1",
    intent,
    {
      intent_id: intent.intent_id,
      robot_id: intent.robot_id,
      capability: intent.capability,
      decision: Allow,
      reason: Safe,
      detail: "allowed",
    },
    plan.task.now_ms,
  )
}

///|
test "task message status advances from evaluation to runtime preflight" {
  let plan = message_plan()
  let draft = plan.intent_draft.unwrap()
  let missing = @moonbook.project_task_message_execution_status(
    "/moonbook/task-messages/\{plan.task.task_id}.json",
    plan,
    @moonbook.task_message_execution_evidence(runtime_status="not-running"),
  )
  assert_eq(missing.stage, "needs-evaluation")
  assert_eq(
    missing.next_route,
    "/api/moonbook/task-messages/\{plan.task.task_id}/evaluate",
  )
  let evaluated = ready_receipt(plan, draft)
  let dry_run = @core.dry_run_evidence(
    @moonbook.task_message_dry_run_id(draft, plan.task.now_ms),
    evaluated,
    "dry-run",
    plan.task.now_ms,
  )
  let approval = @core.approval_record(
    @moonbook.task_message_approval_id(draft, plan.task.now_ms),
    dry_run.dry_run_receipt_id,
    evaluated.intent,
    plan.task.requested_by,
    "approved",
    plan.task.now_ms,
  )
  let preflight = @moonbook.project_task_message_execution_status(
    "/moonbook/task-messages/\{plan.task.task_id}.json",
    plan,
    @moonbook.task_message_execution_evidence(
      evaluated_receipt=Some(evaluated),
      dry_run=Some(dry_run),
      approval=Some(approval),
      runtime_status="not-running",
    ),
  )
  assert_eq(preflight.stage, "runtime-required")
  assert_eq(preflight.next_route, "/api/runtime/supervisor/start")
  assert_true(preflight.runtime_required)
}

///|
test "task message status reports completed bridge dispatch" {
  let plan = message_plan()
  let draft = plan.intent_draft.unwrap()
  let evaluated = ready_receipt(plan, draft)
  let dry_run = @core.dry_run_evidence(
    @moonbook.task_message_dry_run_id(draft, plan.task.now_ms),
    evaluated,
    "dry-run",
    plan.task.now_ms,
  )
  let approval = @core.approval_record(
    @moonbook.task_message_approval_id(draft, plan.task.now_ms),
    dry_run.dry_run_receipt_id,
    evaluated.intent,
    plan.task.requested_by,
    "approved",
    plan.task.now_ms,
  )
  let executed = @core.executed_receipt(
    @moonbook.task_message_execution_receipt_id(draft),
    evaluated,
    plan.task.now_ms,
    telemetry_frame_count=1,
  )
  let dispatch = @core.bridge_dispatch_evidence(
    @moonbook.task_message_bridge_dispatch_id(draft, plan.task.now_ms),
    "request-execute-\{draft.intent_id}-\{plan.task.now_ms}",
    "sdk-e1",
    plan.task.robot_id,
    "ExecuteIntent",
    "POST",
    "/intents/execute",
    draft.intent_id,
    executed.receipt_id,
    "Accepted",
    "executed",
    plan.task.now_ms,
  )
  let status = @moonbook.project_task_message_execution_status(
    "/moonbook/task-messages/\{plan.task.task_id}.json",
    plan,
    @moonbook.task_message_execution_evidence(
      evaluated_receipt=Some(evaluated),
      dry_run=Some(dry_run),
      approval=Some(approval),
      execution_receipt=Some(executed),
      bridge_dispatch=Some(dispatch),
      runtime_status="running",
    ),
  )
  assert_eq(status.stage, "completed")
  assert_true(status.executed)
  assert_eq(status.bridge_status, "Accepted")
}
