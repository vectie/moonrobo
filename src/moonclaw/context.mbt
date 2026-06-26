///|
pub(all) struct MoonClawContextPack {
  pack_id : String
  robot_id : @core.RobotId
  resident : @resident.ResidentRobotAgent
  memory : @moonbook.MoonBookMemoryPack
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
pub fn context_pack(
  resident : @resident.ResidentRobotAgent,
  reviews : Array[@review.ProcessReview],
  memory : @moonbook.MoonBookMemoryPack,
  tool_registry : @tool_registry.ToolRegistry,
  readiness : @readiness.PlatformReadinessReport,
  readiness_plan : @readiness.PlatformReadinessPlan,
  gateway : @gateway.MoonroboGatewayStatus,
  generated_at_ms : Int64,
) -> MoonClawContextPack {
  {
    pack_id: "moonclaw-context-\{resident.robot_id}-\{generated_at_ms}",
    robot_id: resident.robot_id,
    resident,
    memory,
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
pub fn context_pack_json(
  context : MoonClawContextPack,
  indent? : Int = 2,
) -> String {
  context.to_json().stringify(indent~)
}
