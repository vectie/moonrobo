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
pub(all) struct RobotRoutineWorkEvidence {
  status : String
  ready : Bool
  next_route : String
  message : String
  latest_gateway_command_path : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RobotPlatformWorkItem {
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
pub(all) struct RobotPlatformQueue {
  queue_id : String
  robot_id : @core.RobotId
  resident_id : String
  generated_at_ms : Int64
  item_count : Int
  high_priority_count : Int
  items : Array[RobotPlatformWorkItem]
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
pub fn robot_routine_work_evidence(
  status : String,
  ready : Bool,
  next_route : String,
  message : String,
  latest_gateway_command_path? : String = "",
) -> RobotRoutineWorkEvidence {
  { status, ready, next_route, message, latest_gateway_command_path }
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
) -> RobotPlatformWorkItem {
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
fn add_bridge_work(
  items : Array[RobotPlatformWorkItem],
  resident : @resident.ResidentRobotAgent,
) -> Unit {
  if resident.availability == "bridge-missing" {
    items.push(
      work_item(
        "work-\{resident.robot_id}-start-runtime",
        "start-runtime",
        100,
        "Start supervised runtime",
        "Robot resident needs its supervised runtime before bridge validation",
        resident.robot_id,
        "/api/runtime/supervisor/start",
        "Physical-world agents need supervised runtime health before bridge validation, observation, or command work",
      ),
    )
  }
}

///|
fn add_review_work(
  items : Array[RobotPlatformWorkItem],
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
  items : Array[RobotPlatformWorkItem],
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
  items : Array[RobotPlatformWorkItem],
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
  items : Array[RobotPlatformWorkItem],
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
fn add_robot_routine_work(
  items : Array[RobotPlatformWorkItem],
  resident : @resident.ResidentRobotAgent,
  evidence : RobotRoutineWorkEvidence?,
) -> Unit {
  match evidence {
    Some(evidence) =>
      if evidence.ready {
        items.push(
          work_item(
            "work-\{resident.robot_id}-gateway-command",
            "submit-gateway-command",
            83,
            "Run MoonClaw gateway command",
            evidence.message,
            resident.robot_id,
            @gateway.gateway_command_path(),
            "Moonrobo gateway is live-ready; MoonClaw should choose a command and submit it to the gateway before sustained proof sessions",
          ),
        )
      }
    None => ()
  }
}

///|
fn add_observation_work(
  items : Array[RobotPlatformWorkItem],
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
            "/api/moontown/tasks/observe-run",
            "MoonClaw should call Moonrobo's bounded observation tool before policy or dataset work",
          ),
        )
      }
  }
}

///|
fn add_dataset_work(
  items : Array[RobotPlatformWorkItem],
  episodes : Array[DatasetWorkEvidence],
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
          "Dataset curation should mark replay frames before MoonClaw learned-policy analysis",
        ),
      )
    }
  }
}

///|
fn add_task_message_work(
  items : Array[RobotPlatformWorkItem],
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
fn high_priority_count(items : Array[RobotPlatformWorkItem]) -> Int {
  let mut count = 0
  for item in items {
    if item.priority >= 80 {
      count += 1
    }
  }
  count
}

///|
pub fn project(
  robot_id : @core.RobotId,
  resident : @resident.ResidentRobotAgent,
  reviews : Array[@review.ProcessReview],
  task_messages : Array[TaskMessageWorkEvidence],
  episodes : Array[DatasetWorkEvidence],
  generated_at_ms : Int64,
  runtime_calibration? : RuntimeCalibrationWorkEvidence? = None,
  robot_routine? : RobotRoutineWorkEvidence? = None,
  proof_session? : ProofSessionWorkEvidence? = None,
) -> RobotPlatformQueue {
  let items : Array[RobotPlatformWorkItem] = []
  add_bridge_work(items, resident)
  add_calibration_work(items, runtime_calibration)
  add_review_work(items, reviews)
  add_task_message_work(items, task_messages)
  add_execution_proof_work(items, resident)
  add_robot_routine_work(items, resident, robot_routine)
  add_proof_session_work(items, resident, proof_session)
  add_observation_work(items, resident)
  add_dataset_work(items, episodes)
  items.sort_by((left, right) => right.priority - left.priority)
  {
    queue_id: "platform-queue-\{robot_id}-\{generated_at_ms}",
    robot_id,
    resident_id: resident.resident_id,
    generated_at_ms,
    item_count: items.length(),
    high_priority_count: high_priority_count(items),
    items,
  }
}

///|
pub fn queue_json(queue : RobotPlatformQueue, indent? : Int = 2) -> String {
  queue.to_json().stringify(indent~)
}
