///|
pub(all) struct MoonBookConversationTurn {
  turn_id : String
  message_id : String
  task_id : String
  created_at_ms : Int64
  user_text : String
  robo_text : String
  classification : String
  stage : String
  next_route : String
  requires_review : Bool
  physical_execution_allowed : Bool
  message_path : String
  evidence_paths : Array[String]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonBookConversationThread {
  thread_id : String
  turn_count : Int
  latest_task_id : String
  turns : Array[MoonBookConversationTurn]
} derive(Debug, Eq, ToJson, FromJson)

///|
fn turn_id(plan : @task.RobotTaskMessagePlan) -> String {
  if plan.message_id == "" {
    plan.task.task_id
  } else {
    plan.message_id
  }
}

///|
fn robo_text(status : TaskMessageExecutionStatus) -> String {
  if status.summary == "" {
    status.stage
  } else {
    "\{status.stage}: \{status.summary}"
  }
}

///|
pub fn task_message_conversation_turn(
  message_path : String,
  plan : @task.RobotTaskMessagePlan,
  status : TaskMessageExecutionStatus,
) -> MoonBookConversationTurn {
  {
    turn_id: turn_id(plan),
    message_id: plan.message_id,
    task_id: plan.task.task_id,
    created_at_ms: plan.task.now_ms,
    user_text: plan.task.goal,
    robo_text: robo_text(status),
    classification: plan.classification,
    stage: status.stage,
    next_route: status.next_route,
    requires_review: plan.requires_review,
    physical_execution_allowed: plan.physical_execution_allowed,
    message_path,
    evidence_paths: status.evidence_paths,
  }
}

///|
pub fn task_message_conversation_thread(
  turns : Array[MoonBookConversationTurn],
) -> MoonBookConversationThread {
  let latest_task_id = if turns.is_empty() {
    ""
  } else {
    turns[turns.length() - 1].task_id
  }
  {
    thread_id: "moonbook-task-messages",
    turn_count: turns.length(),
    latest_task_id,
    turns,
  }
}
