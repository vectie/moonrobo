///|
pub(all) struct DatasetWorkEvidence {
  episode : @dataset.DatasetEpisode
  quality : @dataset.DatasetQualityReport
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct TaskMessageWorkEvidence {
  message_path : String
  plan : @task.RobotTaskMessagePlan
  evaluated : Bool
  dry_run_collected : Bool
  approved : Bool
  executed : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RuntimeCalibrationWorkEvidence {
  plan_id : String
  status : String
  action_count : Int
  blocking_action_count : Int
  first_action_id : String
  first_blocker_code : String
  first_owner : String
  first_summary : String
  first_next_step : String
  plan_path : String
  pending_revalidation : Bool
  resolution_id : String
  resolution_status : String
  validation_path : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ProofSessionWorkEvidence {
  status : String
  ready : Bool
  completed_count : Int
  total_count : Int
  percent : Int
  next_route : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct AgentWorkItem {
  work_id : String
  kind : String
  priority : Int
  title : String
  summary : String
  target_id : String
  target_path : String
  reason : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct AgentWorkQueue {
  queue_id : String
  robot_id : @core.RobotId
  resident_id : String
  generated_at_ms : Int64
  item_count : Int
  high_priority_count : Int
  next_item : AgentWorkItem?
  items : Array[AgentWorkItem]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct AgentNextAction {
  action_id : String
  work_id : String
  kind : String
  title : String
  http_method : String
  route : String
  body_schema : String
  body_template : Json?
  execution_mode : String
  physical_execution_allowed : Bool
  safety_note : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct AgentNextActionPlan {
  queue : AgentWorkQueue
  action : AgentNextAction?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn dataset_work_evidence(
  episode : @dataset.DatasetEpisode,
  quality : @dataset.DatasetQualityReport,
) -> DatasetWorkEvidence {
  { episode, quality }
}

///|
pub fn task_message_work_evidence(
  message_path : String,
  plan : @task.RobotTaskMessagePlan,
  evaluated? : Bool = false,
  dry_run_collected? : Bool = false,
  approved? : Bool = false,
  executed? : Bool = false,
) -> TaskMessageWorkEvidence {
  { message_path, plan, evaluated, dry_run_collected, approved, executed }
}

///|
pub fn runtime_calibration_work_evidence(
  plan_id : String,
  status : String,
  action_count : Int,
  blocking_action_count : Int,
  first_action_id : String,
  first_blocker_code : String,
  first_owner : String,
  first_summary : String,
  first_next_step : String,
  plan_path : String,
  pending_revalidation? : Bool = false,
  resolution_id? : String = "",
  resolution_status? : String = "",
  validation_path? : String = "/api/runtime/validation/session",
) -> RuntimeCalibrationWorkEvidence {
  {
    plan_id,
    status,
    action_count,
    blocking_action_count,
    first_action_id,
    first_blocker_code,
    first_owner,
    first_summary,
    first_next_step,
    plan_path,
    pending_revalidation,
    resolution_id,
    resolution_status,
    validation_path,
  }
}

///|
pub fn proof_session_work_evidence(
  status : String,
  ready : Bool,
  completed_count : Int,
  total_count : Int,
  percent : Int,
  next_route : String,
  message : String,
) -> ProofSessionWorkEvidence {
  { status, ready, completed_count, total_count, percent, next_route, message }
}

///|
fn next_action(
  item : AgentWorkItem,
  http_method : String,
  route : String,
  body_schema : String,
  body_template : Json?,
  execution_mode : String,
  safety_note : String,
) -> AgentNextAction {
  {
    action_id: "action-\{item.work_id}",
    work_id: item.work_id,
    kind: item.kind,
    title: item.title,
    http_method,
    route,
    body_schema,
    body_template,
    execution_mode,
    physical_execution_allowed: false,
    safety_note,
  }
}

///|
fn next_action_from_capability(
  item : AgentWorkItem,
  capability : @tool_registry.ToolCapability,
  route : String,
  body_template : Json?,
) -> AgentNextAction {
  {
    action_id: "action-\{item.work_id}",
    work_id: item.work_id,
    kind: item.kind,
    title: item.title,
    http_method: capability.http_method,
    route,
    body_schema: capability.body_schema,
    body_template,
    execution_mode: capability.execution_mode,
    physical_execution_allowed: capability.physical_execution_allowed,
    safety_note: capability.safety_note,
  }
}

///|
fn registry_action(
  registry : @tool_registry.ToolRegistry,
  item : AgentWorkItem,
  capability_id : String,
  route : String,
  body_template : Json?,
  fallback : AgentNextAction,
) -> AgentNextAction {
  match @tool_registry.find_capability(registry, capability_id) {
    Some(capability) =>
      next_action_from_capability(
        item,
        capability,
        if route == "" {
          capability.route
        } else {
          route
        },
        body_template,
      )
    None => fallback
  }
}

///|
fn observation_run_template() -> Json {
  {
    "task_id": "standing-goal-agent-process",
    "goal": "agentic bounded observation process",
    "now_ms": "0",
    "frame_count": 3,
    "frame_interval_ms": "1",
  }
}

///|
fn replay_annotation_template(item : AgentWorkItem) -> Json {
  {
    "annotation_id": "annotation-\{item.target_id}-curation",
    "frame_id": "",
    "label": "usable",
    "note": "operator marked replay evidence usable",
    "severity": "info",
    "requester": { "kind": "operator", "id": "cockpit" },
    "created_at_ms": "0",
  }
}

///|
fn policy_evaluation_template(item : AgentWorkItem) -> Json {
  {
    "proposal": {
      "proposal_id": "proposal-\{item.target_id}",
      "policy_id": "policy-offline-review",
      "episode_id": item.target_id,
      "robot_id": "",
      "capability": "control.high.walk",
      "parameters": { "x": "0.10", "yaw": "0.00", "duration_ms": "1000" },
      "confidence": 0.80,
      "created_at_ms": "0",
    },
    "evaluation_id": "policy-eval-\{item.target_id}",
    "receipt_id": "receipt-policy-\{item.target_id}",
    "now_ms": "0",
    "telemetry_age_ms": 10,
    "quality_report": Json::null(),
  }
}

///|
fn proof_session_template(item : AgentWorkItem) -> Json {
  {
    "session_id": "proof-session-\{item.target_id}",
    "task_message": {
      "message_id": "proof-session-\{item.target_id}",
      "robot_id": "",
      "requested_by": { "kind": "moontown", "id": "moonclaw" },
      "message": "walk forward",
      "now_ms": "0",
    },
    "iterations": 3,
    "max_steps": 8,
    "allow_dispatch": false,
    "auto_continue": true,
    "bootstrap": true,
    "stop_when_ready": true,
  }
}

///|
pub fn action_for_item(item : AgentWorkItem) -> AgentNextAction {
  match item.kind {
    "connect-bridge" =>
      next_action(
        item,
        "GET",
        "/api/bridge/sidecar",
        "none",
        None,
        "read-only",
        "Inspect bridge launchability only; do not start or command hardware from this action.",
      )
    "review-evidence" =>
      next_action(
        item,
        "GET",
        item.target_path,
        "none",
        None,
        "read-only",
        "Open review evidence for operator decision; do not mutate review state automatically.",
      )
    "calibrate-runtime" =>
      next_action(
        item,
        "GET",
        item.target_path,
        "none",
        None,
        "operator-calibration",
        "Inspect the runtime calibration plan and resolve listed blockers before any physical execution path is used.",
      )
    "validate-runtime" =>
      next_action(
        item,
        "POST",
        item.target_path,
        "RuntimeValidationSessionRequest",
        None,
        "operator-validation",
        "Rerun repeated runtime validation so readiness evidence is current; this probes the gateway but does not dispatch physical tasks.",
      )
    "observe" =>
      next_action(
        item,
        "POST",
        "/api/moonclaw/run-next",
        "AgentProcessRunRequest",
        Some(observation_run_template()),
        "bounded-process",
        "Runs only the bounded MoonClaw process gate; physical execution remains blocked by bridge and safety gates.",
      )
    "bind-execution-feedback" =>
      next_action(
        item,
        "POST",
        item.target_path,
        "TaskExecutionFeedbackRequest",
        None,
        "bounded-verification",
        "Bind telemetry feedback to the existing execution snapshot before scheduling more robot work; this verifies evidence and does not command hardware.",
      )
    "run-proof-session" =>
      next_action(
        item,
        "POST",
        item.target_path,
        "PlatformProofSessionRequest",
        Some(proof_session_template(item)),
        "bounded-proof",
        "Run repeated closed-loop proof attempts through Moonrobo gates with allow_dispatch=false; this collects evidence and stops on blockers.",
      )
    "watch-observation" =>
      next_action(
        item,
        "GET",
        item.target_path,
        "none",
        None,
        "read-only",
        "Inspect active replay evidence and wait for the observation to stop before scheduling another run.",
      )
    "annotate-replay" =>
      next_action(
        item,
        "POST",
        item.target_path,
        "ReplayAnnotationRequest",
        Some(replay_annotation_template(item)),
        "operator-curation",
        "Creates curation evidence only; annotation does not authorize policy or hardware execution.",
      )
    "repair-dataset" | "repair-policy-quality" =>
      next_action(
        item,
        "GET",
        item.target_path,
        "none",
        None,
        "read-only",
        "Inspect quality blockers before collecting or curating more evidence.",
      )
    "evaluate-policy" =>
      next_action(
        item,
        "POST",
        "/api/policies/evaluate",
        "PolicyEvaluationRequest",
        Some(policy_evaluation_template(item)),
        "offline-policy",
        "Policy evaluation is receipt-only and cannot execute hardware directly.",
      )
    "review-policy-safety"
    | "dry-run-policy-proposal"
    | "approve-policy-proposal"
    | "review-policy-proposal" =>
      next_action(
        item,
        "GET",
        item.target_path,
        "none",
        None,
        "read-only",
        "Inspect policy evaluation evidence; follow dry-run and approval routes explicitly if needed.",
      )
    "review-command-message" | "review-maintenance-message" =>
      next_action(
        item,
        "GET",
        item.target_path,
        "none",
        None,
        "operator-review",
        "Open the persisted task-message plan; use the listed gated route explicitly after review.",
      )
    "evaluate-command-message"
    | "dry-run-command-message"
    | "approve-command-message"
    | "execute-command-message" =>
      next_action(
        item,
        "POST",
        item.target_path,
        "none",
        None,
        "operator-safety",
        "Advance the persisted task-message safety route; agent dispatch remains disabled for command-message gates.",
      )
    _ =>
      next_action(
        item,
        "GET",
        item.target_path,
        "none",
        None,
        "read-only",
        "Unknown work kind defaults to read-only inspection.",
      )
  }
}

///|
pub fn next_action_plan(queue : AgentWorkQueue) -> AgentNextActionPlan {
  {
    queue,
    action: match queue.next_item {
      Some(item) => Some(action_for_item(item))
      None => None
    },
  }
}

///|
pub fn action_for_item_with_registry(
  item : AgentWorkItem,
  registry : @tool_registry.ToolRegistry,
) -> AgentNextAction {
  let fallback = action_for_item(item)
  match item.kind {
    "connect-bridge" =>
      registry_action(registry, item, "bridge.sidecar.read", "", None, fallback)
    "calibrate-runtime" =>
      registry_action(
        registry,
        item,
        "runtime.calibration.read",
        "",
        None,
        fallback,
      )
    "validate-runtime" =>
      registry_action(
        registry,
        item,
        "runtime.validation.session",
        "",
        None,
        fallback,
      )
    "observe" =>
      registry_action(
        registry,
        item,
        "moonclaw.run-next",
        "",
        Some(observation_run_template()),
        fallback,
      )
    "bind-execution-feedback" =>
      registry_action(
        registry,
        item,
        "execution.feedback-bind",
        "",
        None,
        fallback,
      )
    "run-proof-session" =>
      registry_action(
        registry,
        item,
        "proof.session-run",
        "",
        Some(proof_session_template(item)),
        fallback,
      )
    "annotate-replay" =>
      registry_action(
        registry,
        item,
        "replay.annotation.write",
        item.target_path,
        Some(replay_annotation_template(item)),
        fallback,
      )
    "evaluate-policy" =>
      registry_action(
        registry,
        item,
        "policy.evaluate",
        "",
        Some(policy_evaluation_template(item)),
        fallback,
      )
    "evaluate-command-message"
    | "dry-run-command-message"
    | "approve-command-message"
    | "execute-command-message" =>
      registry_action(
        registry,
        item,
        "task-message.advance",
        item.target_path,
        None,
        fallback,
      )
    _ => fallback
  }
}

///|
pub fn next_action_plan_with_registry(
  queue : AgentWorkQueue,
  registry : @tool_registry.ToolRegistry,
) -> AgentNextActionPlan {
  {
    queue,
    action: match queue.next_item {
      Some(item) => Some(action_for_item_with_registry(item, registry))
      None => None
    },
  }
}

///|
fn work_item(
  work_id : String,
  kind : String,
  priority : Int,
  title : String,
  summary : String,
  target_id : String,
  target_path : String,
  reason : String,
) -> AgentWorkItem {
  { work_id, kind, priority, title, summary, target_id, target_path, reason }
}

///|
fn has_quality_issue(
  report : @dataset.DatasetQualityReport,
  code : String,
) -> Bool {
  report.issues.any(issue => issue.code == code)
}

///|
fn unresolved_review(review : @review.ProcessReview) -> Bool {
  review.disposition == NeedsHumanReview
}

///|
fn policy_for_episode(
  evaluations : Array[@policy.PolicyEvaluationReceipt],
  episode_id : String,
) -> Bool {
  evaluations.any(evaluation => evaluation.proposal.episode_id == episode_id)
}

///|
fn latest_policy_evaluation(
  evaluations : Array[@policy.PolicyEvaluationReceipt],
) -> @policy.PolicyEvaluationReceipt? {
  if evaluations.is_empty() {
    None
  } else {
    Some(evaluations[evaluations.length() - 1])
  }
}

///|
fn add_bridge_work(
  items : Array[AgentWorkItem],
  resident : @resident.ResidentRobotAgent,
) -> Unit {
  if resident.availability == "bridge-missing" {
    items.push(
      work_item(
        "work-\{resident.robot_id}-connect-bridge",
        "connect-bridge",
        100,
        "Connect robot bridge",
        "Robot resident cannot launch its bridge command",
        resident.robot_id,
        "/api/bridge/sidecar",
        "Physical-world agents need read-only bridge health before any observation or command loop",
      ),
    )
  }
}

///|
fn add_review_work(
  items : Array[AgentWorkItem],
  reviews : Array[@review.ProcessReview],
) -> Unit {
  for review in reviews {
    if unresolved_review(review) {
      items.push(
        work_item(
          "work-\{review.review_id}",
          "review-evidence",
          90,
          "Review robot evidence",
          review.summary,
          review.review_id,
          "/api/reviews/\{review.review_id}",
          "Human review is required before scheduling the next autonomous robot process",
        ),
      )
    }
  }
}

///|
fn add_calibration_work(
  items : Array[AgentWorkItem],
  evidence : RuntimeCalibrationWorkEvidence?,
) -> Unit {
  match evidence {
    Some(plan) =>
      if plan.pending_revalidation {
        let summary = if plan.resolution_id == "" {
          plan.first_summary
        } else {
          "Calibration resolution \{plan.resolution_id} is waiting for repeated runtime validation"
        }
        items.push(
          work_item(
            "work-\{plan.plan_id}-validate-runtime",
            "validate-runtime",
            101,
            "Validate runtime readiness",
            summary,
            plan.plan_id,
            plan.validation_path,
            "Rerun runtime validation before retrying physical dispatch for this RoboBook",
          ),
        )
      } else if plan.status == "needs-calibration" &&
        plan.blocking_action_count > 0 {
        items.push(
          work_item(
            "work-\{plan.plan_id}-calibrate-runtime",
            "calibrate-runtime",
            95,
            "Calibrate runtime readiness",
            plan.first_summary,
            plan.plan_id,
            plan.plan_path,
            plan.first_next_step,
          ),
        )
      }
    None => ()
  }
}

///|
fn add_execution_proof_work(
  items : Array[AgentWorkItem],
  resident : @resident.ResidentRobotAgent,
) -> Unit {
  match resident.latest_execution {
    Some(execution) =>
      if !execution.verified {
        items.push(
          work_item(
            "work-\{execution.snapshot_id}-bind-feedback",
            "bind-execution-feedback",
            89,
            "Bind latest execution feedback",
            execution.message,
            execution.snapshot_id,
            "/api/moonrobo/executions/feedback",
            "The latest user task reached execution evidence but needs telemetry feedback bound into durable proof",
          ),
        )
      }
    None => ()
  }
}

///|
fn add_proof_session_work(
  items : Array[AgentWorkItem],
  resident : @resident.ResidentRobotAgent,
  proof : ProofSessionWorkEvidence?,
) -> Unit {
  match proof {
    Some(proof) =>
      if !proof.ready {
        items.push(
          work_item(
            "work-\{resident.robot_id}-proof-session",
            "run-proof-session",
            82,
            "Run closed-loop proof session",
            proof.message,
            resident.robot_id,
            "/api/moonrobo/proof-session",
            "The closed MoonClaw-to-Moonrobo loop is \{proof.completed_count}/\{proof.total_count} proven; run a bounded proof session until verified or safely blocked",
          ),
        )
      }
    None => ()
  }
}

///|
fn add_observation_work(
  items : Array[AgentWorkItem],
  resident : @resident.ResidentRobotAgent,
) -> Unit {
  match resident.active_observation {
    Some(session) =>
      items.push(
        work_item(
          "work-\{session.session_id}-watch-observation",
          "watch-observation",
          35,
          "Watch active observation",
          "Observation session is still collecting physical evidence",
          session.session_id,
          "/api/replays/\{session.session_id}",
          "Avoid overlapping robot evidence collection while an observation is active",
        ),
      )
    None =>
      if resident.latest_observation is None && resident.availability == "ready" {
        items.push(
          work_item(
            "work-\{resident.robot_id}-observe",
            "observe",
            80,
            "Collect first observation",
            "No replay evidence exists for this resident robot",
            resident.robot_id,
            "/api/moonclaw/run-next",
            "The agent loop needs fresh physical evidence before policy or dataset work",
          ),
        )
      }
  }
}

///|
fn add_dataset_work(
  items : Array[AgentWorkItem],
  episodes : Array[DatasetWorkEvidence],
  evaluations : Array[@policy.PolicyEvaluationReceipt],
) -> Unit {
  for evidence in episodes {
    let episode = evidence.episode
    let quality = evidence.quality
    if quality.blocker_count > 0 {
      items.push(
        work_item(
          "work-\{episode.session_id}-repair-dataset",
          "repair-dataset",
          75,
          "Repair dataset episode",
          "Episode quality has blockers",
          episode.session_id,
          "/api/datasets/episodes/\{episode.session_id}/quality",
          "Blocked dataset evidence cannot feed policy proposal review",
        ),
      )
    } else if has_quality_issue(quality, "missing-annotations") {
      items.push(
        work_item(
          "work-\{episode.session_id}-annotate-replay",
          "annotate-replay",
          70,
          "Annotate replay evidence",
          "Replay is usable but lacks curation annotations",
          episode.session_id,
          "/api/replays/\{episode.session_id}/annotations",
          "Dataset curation should mark replay frames before policy evaluation",
        ),
      )
    } else if !policy_for_episode(evaluations, episode.episode_id) {
      items.push(
        work_item(
          "work-\{episode.session_id}-evaluate-policy",
          "evaluate-policy",
          60,
          "Evaluate policy proposal",
          "Curated replay evidence is ready for offline policy gating",
          episode.episode_id,
          "/api/policies/evaluate",
          "Policies can propose intents only after replay evidence clears quality gates",
        ),
      )
    }
  }
}

///|
fn add_policy_work(
  items : Array[AgentWorkItem],
  evaluations : Array[@policy.PolicyEvaluationReceipt],
) -> Unit {
  match latest_policy_evaluation(evaluations) {
    None => ()
    Some(evaluation) => {
      let (kind, priority, title, reason) = match evaluation.gate_status {
        "blocked-quality" =>
          (
            "repair-policy-quality", 76, "Repair policy dataset quality", "Latest policy proposal is blocked by dataset quality",
          )
        "blocked-safety" =>
          (
            "review-policy-safety", 85, "Review policy safety block", "Latest policy proposal failed the physical safety gate",
          )
        "requires-dry-run" =>
          (
            "dry-run-policy-proposal", 65, "Dry-run policy proposal", "Latest policy proposal requires dry-run evidence before approval review",
          )
        "requires-approval" =>
          (
            "approve-policy-proposal", 64, "Approve policy proposal", "Latest policy proposal requires explicit operator approval",
          )
        _ =>
          (
            "review-policy-proposal", 50, "Review policy proposal", "Latest policy proposal remains review-only and cannot execute hardware directly",
          )
      }
      items.push(
        work_item(
          "work-\{evaluation.evaluation_id}",
          kind,
          priority,
          title,
          evaluation.reason,
          evaluation.evaluation_id,
          "/api/policies/evaluations/\{evaluation.evaluation_id}",
          reason,
        ),
      )
    }
  }
}

///|
fn add_task_message_work(
  items : Array[AgentWorkItem],
  messages : Array[TaskMessageWorkEvidence],
) -> Unit {
  for evidence in messages {
    let plan = evidence.plan
    if plan.requires_review && !plan.physical_execution_allowed {
      let (kind, priority, title, reason) = match plan.classification {
        "command-intent-review" => command_message_work_kind(evidence)
        "maintenance-review" =>
          (
            "review-maintenance-message", 72, "Review maintenance task message",
            "Maintenance language should become scheduled work before touching bridge or hardware",
          )
        _ =>
          (
            "review-task-message", 55, "Review task message", "Task message needs operator review before further routing",
          )
      }
      items.push(
        work_item(
          "work-\{plan.task.task_id}",
          kind,
          priority,
          title,
          plan.task.goal,
          plan.task.task_id,
          task_message_target_path(plan.task.task_id, kind),
          reason,
        ),
      )
    }
  }
}

///|
fn task_message_target_path(task_id : String, kind : String) -> String {
  match kind {
    "evaluate-command-message" =>
      "/api/moonbook/task-messages/\{task_id}/evaluate"
    "dry-run-command-message" =>
      "/api/moonbook/task-messages/\{task_id}/dry-run"
    "approve-command-message" =>
      "/api/moonbook/task-messages/\{task_id}/approve"
    "execute-command-message" =>
      "/api/moonbook/task-messages/\{task_id}/execute-sidecar"
    _ => "/api/moonbook/task-messages/\{task_id}"
  }
}

///|
fn command_message_work_kind(
  evidence : TaskMessageWorkEvidence,
) -> (String, Int, String, String) {
  if evidence.executed {
    (
      "review-command-message", 20, "Review executed command task", "Command task already has an execution receipt; inspect the persisted evidence only",
    )
  } else if evidence.plan.intent_draft is None {
    (
      "review-command-message", 88, "Review command task message", "Command language needs an intent draft before any robot action",
    )
  } else if !evidence.evaluated {
    (
      "evaluate-command-message", 88, "Evaluate reviewed command", "Evaluate the persisted task-message intent draft through the safety gate",
    )
  } else if !evidence.dry_run_collected {
    (
      "dry-run-command-message", 87, "Dry-run reviewed command", "Collect dry-run evidence for the persisted task-message intent",
    )
  } else if !evidence.approved {
    (
      "approve-command-message", 86, "Approve reviewed command", "Record operator approval for the reviewed task-message intent",
    )
  } else {
    (
      "execute-command-message", 85, "Execute reviewed command", "Execute only after task-message review, dry-run evidence, and approval are present",
    )
  }
}

///|
fn high_priority_count(items : Array[AgentWorkItem]) -> Int {
  let mut count = 0
  for item in items {
    if item.priority >= 80 {
      count += 1
    }
  }
  count
}

///|
fn next_item(items : Array[AgentWorkItem]) -> AgentWorkItem? {
  if items.is_empty() {
    None
  } else {
    Some(items[0])
  }
}

///|
pub fn project(
  robot_id : @core.RobotId,
  resident : @resident.ResidentRobotAgent,
  reviews : Array[@review.ProcessReview],
  task_messages : Array[TaskMessageWorkEvidence],
  episodes : Array[DatasetWorkEvidence],
  policy_evaluations : Array[@policy.PolicyEvaluationReceipt],
  generated_at_ms : Int64,
  runtime_calibration? : RuntimeCalibrationWorkEvidence? = None,
  proof_session? : ProofSessionWorkEvidence? = None,
) -> AgentWorkQueue {
  let items : Array[AgentWorkItem] = []
  add_bridge_work(items, resident)
  add_calibration_work(items, runtime_calibration)
  add_review_work(items, reviews)
  add_task_message_work(items, task_messages)
  add_execution_proof_work(items, resident)
  add_proof_session_work(items, resident, proof_session)
  add_observation_work(items, resident)
  add_dataset_work(items, episodes, policy_evaluations)
  add_policy_work(items, policy_evaluations)
  items.sort_by((left, right) => right.priority - left.priority)
  {
    queue_id: "work-queue-\{robot_id}-\{generated_at_ms}",
    robot_id,
    resident_id: resident.resident_id,
    generated_at_ms,
    item_count: items.length(),
    high_priority_count: high_priority_count(items),
    next_item: next_item(items),
    items,
  }
}

///|
pub fn queue_json(queue : AgentWorkQueue, indent? : Int = 2) -> String {
  queue.to_json().stringify(indent~)
}
