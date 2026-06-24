///|
pub(all) enum RobotProcessAction {
  Observe
  ReviewEvidence
  RemediateReadiness
  Hold
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonClawContextPack {
  pack_id : String
  robot_id : @core.RobotId
  resident : @resident.ResidentRobotAgent
  memory : @moonbook.MoonBookMemoryPack
  tool_registry : @tool_registry.ToolRegistry
  readiness : @readiness.PlatformReadinessReport
  readiness_plan : @readiness.PlatformReadinessPlan
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
  memory : @moonbook.MoonBookMemoryPack,
  tool_registry : @tool_registry.ToolRegistry,
  readiness : @readiness.PlatformReadinessReport,
  readiness_plan : @readiness.PlatformReadinessPlan,
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
    None => context.memory.cards.map(card => card.evidence_path)
  }
}

///|
fn tool_route_available(context : MoonClawContextPack, route : String) -> Bool {
  context.tool_registry.providers.any(fn(provider) {
    provider.capabilities.any(fn(capability) { capability.route == route })
  })
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
fn execution_review_plan(
  context : MoonClawContextPack,
  execution : @resident.ResidentExecutionSummary,
) -> MoonClawProcessPlan {
  {
    plan_id: "moonclaw-plan-\{context.robot_id}-execution-proof",
    action: ReviewEvidence,
    summary: "Inspect latest task execution proof before scheduling another robot task",
    steps: [
      {
        label: "Open execution proof",
        route: "/api/moonrobo/executions",
        reason: execution.message,
      },
      {
        label: "Check runtime health",
        route: "/api/runtime/health",
        reason: "Post-dispatch runtime proof is required before the task is verified",
      },
    ],
    evidence_paths: ["/api/moonrobo/executions"],
  }
}

///|
fn readiness_recovery_action(
  context : MoonClawContextPack,
) -> @readiness.ReadinessAction? {
  for action in context.readiness_plan.actions {
    if action.check_code == "runtime-calibration-clear" ||
      action.check_code == "runtime-validation-current" {
      return Some(action)
    }
  }
  None
}

///|
fn readiness_evidence_paths(context : MoonClawContextPack) -> Array[String] {
  let paths : Array[String] = []
  for check in context.readiness.checks {
    if check.status != "pass" {
      paths.push(check.path)
    }
  }
  paths
}

///|
fn readiness_plan(
  context : MoonClawContextPack,
  action : @readiness.ReadinessAction,
) -> MoonClawProcessPlan {
  {
    plan_id: "moonclaw-plan-\{context.robot_id}-readiness",
    action: RemediateReadiness,
    summary: "Resolve runtime readiness before scheduling another robot task",
    steps: [
      { label: action.title, route: action.route, reason: action.summary },
      {
        label: "Read platform readiness",
        route: "/api/moonrobo/readiness",
        reason: "Confirm the calibration or validation blocker cleared before retrying the task loop",
      },
    ],
    evidence_paths: readiness_evidence_paths(context),
  }
}

///|
fn observe_plan(context : MoonClawContextPack) -> MoonClawProcessPlan {
  let reason = if tool_route_available(
      context, "/api/moontown/tasks/observe-run",
    ) {
    "No human review is pending; Moonrobo exposes the bounded observation task route as a registered tool"
  } else {
    "No human review is pending and the resident is not actively observing"
  }
  {
    plan_id: "moonclaw-plan-\{context.robot_id}-observe",
    action: Observe,
    summary: "Schedule a bounded observation run for fresh physical evidence",
    steps: [
      {
        label: "Run bounded observation",
        route: "/api/moontown/tasks/observe-run",
        reason,
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
  } else if context.resident.latest_execution is Some(execution) &&
    !execution.verified {
    execution_review_plan(context, execution)
  } else if readiness_recovery_action(context) is Some(action) {
    readiness_plan(context, action)
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
  memory : @moonbook.MoonBookMemoryPack,
  tool_registry : @tool_registry.ToolRegistry,
  readiness : @readiness.PlatformReadinessReport,
  readiness_plan : @readiness.PlatformReadinessPlan,
  generated_at_ms : Int64,
) -> MoonClawPlanningResult {
  let context = context_pack(
    resident, reviews, memory, tool_registry, readiness, readiness_plan, generated_at_ms,
  )
  { context, plan: plan_next(context) }
}

///|
pub fn planning_result_json(
  result : MoonClawPlanningResult,
  indent? : Int = 2,
) -> String {
  result.to_json().stringify(indent~)
}
