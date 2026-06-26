///|
pub(all) struct RobotRoutineContextPack {
  pack_id : String
  robot_id : @core.RobotId
  resident : @resident.ResidentRobotAgent
  task_intent : RobotRoutineTaskIntent
  memory : @moonbook.MoonBookMemoryPack
  platform_queue : @platform_queue.RobotPlatformQueue
  tool_registry : @tool_registry.ToolRegistry
  readiness : @readiness.PlatformReadinessReport
  readiness_plan : @readiness.PlatformReadinessPlan
  gateway : @gateway.MoonroboGatewayStatus
  review_count : Int
  needs_human_count : Int
  latest_review : @review.ProcessReview?
  generated_at_ms : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RobotRoutineTaskIntent {
  has_task : Bool
  task_id : String
  message_id : String
  goal : String
  classification : String
  stage : String
  next_route : String
  requires_review : Bool
  physical_execution_allowed : Bool
  message_path : String
  created_at_ms : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn empty_task_intent() -> RobotRoutineTaskIntent {
  {
    has_task: false,
    task_id: "",
    message_id: "",
    goal: "",
    classification: "",
    stage: "no-task",
    next_route: "",
    requires_review: false,
    physical_execution_allowed: false,
    message_path: "",
    created_at_ms: 0L,
  }
}

///|
pub fn task_intent_from_turn(
  turn : @moonbook.MoonBookConversationTurn,
) -> RobotRoutineTaskIntent {
  {
    has_task: true,
    task_id: turn.task_id,
    message_id: turn.message_id,
    goal: turn.user_text,
    classification: turn.classification,
    stage: turn.stage,
    next_route: turn.next_route,
    requires_review: turn.requires_review,
    physical_execution_allowed: turn.physical_execution_allowed,
    message_path: turn.message_path,
    created_at_ms: turn.created_at_ms,
  }
}

///|
fn latest_review(
  reviews : Array[@review.ProcessReview],
) -> @review.ProcessReview? {
  if reviews.is_empty() {
    None
  } else {
    Some(reviews[reviews.length() - 1])
  }
}

///|
pub fn routine_context(
  resident : @resident.ResidentRobotAgent,
  reviews : Array[@review.ProcessReview],
  memory : @moonbook.MoonBookMemoryPack,
  platform_queue : @platform_queue.RobotPlatformQueue,
  tool_registry : @tool_registry.ToolRegistry,
  readiness : @readiness.PlatformReadinessReport,
  readiness_plan : @readiness.PlatformReadinessPlan,
  gateway : @gateway.MoonroboGatewayStatus,
  generated_at_ms : Int64,
  task_intent? : RobotRoutineTaskIntent = empty_task_intent(),
) -> RobotRoutineContextPack {
  {
    pack_id: "robot-routine-context-\{resident.robot_id}-\{generated_at_ms}",
    robot_id: resident.robot_id,
    resident,
    task_intent,
    memory,
    platform_queue,
    tool_registry,
    readiness,
    readiness_plan,
    gateway,
    review_count: resident.review_count,
    needs_human_count: resident.review_count,
    latest_review: latest_review(reviews),
    generated_at_ms,
  }
}

///|
pub fn routine_context_json(
  context : RobotRoutineContextPack,
  indent? : Int = 2,
) -> String {
  context.to_json().stringify(indent~)
}
