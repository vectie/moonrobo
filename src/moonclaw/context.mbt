///|
pub(all) enum RobotProcessAction {
  Observe
  ReviewEvidence
  Hold
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonClawContextPack {
  pack_id : String
  robot_id : @core.RobotId
  resident : @resident.ResidentRobotAgent
  review_count : Int
  needs_human_count : Int
  latest_review : @review.ProcessReview?
  generated_at_ms : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonClawPlanStep {
  label : String
  route : String
  reason : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonClawProcessPlan {
  plan_id : String
  action : RobotProcessAction
  summary : String
  steps : Array[MoonClawPlanStep]
  evidence_paths : Array[String]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonClawPlanningResult {
  context : MoonClawContextPack
  plan : MoonClawProcessPlan
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
  generated_at_ms : Int64,
) -> MoonClawContextPack {
  {
    pack_id: "moonclaw-context-\{resident.robot_id}-\{generated_at_ms}",
    robot_id: resident.robot_id,
    resident,
    review_count: resident.review_count,
    needs_human_count: resident.review_count,
    latest_review: latest_review(reviews),
    generated_at_ms,
  }
}

///|
fn review_evidence_paths(context : MoonClawContextPack) -> Array[String] {
  match context.latest_review {
    Some(review) => review.artifact_paths
    None => []
  }
}

///|
fn review_plan(context : MoonClawContextPack) -> MoonClawProcessPlan {
  {
    plan_id: "moonclaw-plan-\{context.robot_id}-review",
    action: ReviewEvidence,
    summary: "Review process evidence before scheduling another robot task",
    steps: [
      {
        label: "Inspect resident review state",
        route: "/api/moontown/resident",
        reason: "Resident safety state reports review-required",
      },
      {
        label: "Open review queue",
        route: "/api/reviews",
        reason: "Process reviews may include linked artifacts and findings",
      },
    ],
    evidence_paths: review_evidence_paths(context),
  }
}

///|
fn observe_plan(context : MoonClawContextPack) -> MoonClawProcessPlan {
  {
    plan_id: "moonclaw-plan-\{context.robot_id}-observe",
    action: Observe,
    summary: "Schedule a bounded observation run for fresh physical evidence",
    steps: [
      {
        label: "Run bounded observation",
        route: "/api/moontown/tasks/observe-run",
        reason: "No human review is pending and the resident is not actively observing",
      },
      {
        label: "Read replay",
        route: "/api/replays/{session_id}",
        reason: "Use replay evidence for the next diagnosis pass",
      },
    ],
    evidence_paths: [],
  }
}

///|
fn hold_plan(context : MoonClawContextPack) -> MoonClawProcessPlan {
  {
    plan_id: "moonclaw-plan-\{context.robot_id}-hold",
    action: Hold,
    summary: "Hold scheduling while the robot is already observing",
    steps: [
      {
        label: "Inspect resident state",
        route: "/api/moontown/resident",
        reason: "Active observation is already collecting evidence",
      },
    ],
    evidence_paths: [],
  }
}

///|
pub fn plan_next(context : MoonClawContextPack) -> MoonClawProcessPlan {
  if context.needs_human_count > 0 {
    review_plan(context)
  } else if context.resident.active_observation is Some(_) {
    hold_plan(context)
  } else {
    observe_plan(context)
  }
}

///|
pub fn planning_result(
  resident : @resident.ResidentRobotAgent,
  reviews : Array[@review.ProcessReview],
  generated_at_ms : Int64,
) -> MoonClawPlanningResult {
  let context = context_pack(resident, reviews, generated_at_ms)
  { context, plan: plan_next(context) }
}

///|
pub fn planning_result_json(
  result : MoonClawPlanningResult,
  indent? : Int = 2,
) -> String {
  result.to_json().stringify(indent~)
}
