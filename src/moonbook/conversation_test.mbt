///|
fn conversation_plan() -> @task.RobotTaskMessagePlan {
  @task.plan_task_message(
    @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01"),
    @task.task_message_request(
      "conversation-test",
      "noetix-e1-lab-01",
      @core.operator_requester("moonbook-test"),
      "walk forward",
      8000L,
    ),
  ).unwrap()
}

///|
test "task message conversation projects user and robo turn" {
  let plan = conversation_plan()
  let status = @moonbook.project_task_message_execution_status(
    "/moonbook/task-messages/\{plan.task.task_id}.json",
    plan,
    @moonbook.task_message_execution_evidence(runtime_status="not-running"),
  )
  let turn = @moonbook.task_message_conversation_turn(
    "/moonbook/task-messages/\{plan.task.task_id}.json",
    plan,
    status,
  )
  assert_eq(turn.turn_id, "conversation-test")
  assert_eq(turn.task_id, plan.task.task_id)
  assert_eq(turn.user_text, "walk forward")
  assert_eq(turn.stage, "needs-evaluation")
  assert_true(turn.robo_text.contains("needs-evaluation"))
  assert_true(turn.requires_review)
  assert_true(!turn.physical_execution_allowed)
  let thread = @moonbook.task_message_conversation_thread([turn])
  assert_eq(thread.thread_id, "moonbook-task-messages")
  assert_eq(thread.turn_count, 1)
  assert_eq(thread.latest_task_id, plan.task.task_id)
}

///|
test "task message conversation latest task follows turn time" {
  let plan = conversation_plan()
  let status = @moonbook.project_task_message_execution_status(
    "/moonbook/task-messages/\{plan.task.task_id}.json",
    plan,
    @moonbook.task_message_execution_evidence(runtime_status="not-running"),
  )
  let newer = @moonbook.task_message_conversation_turn(
    "/moonbook/task-messages/\{plan.task.task_id}.json",
    plan,
    status,
  )
  let older = {
    ..newer,
    turn_id: "older-bootstrap",
    task_id: "message-bootstrap-first-task",
    created_at_ms: 1L,
  }
  let thread = @moonbook.task_message_conversation_thread([newer, older])
  assert_eq(thread.turn_count, 2)
  assert_eq(thread.latest_task_id, plan.task.task_id)
}
