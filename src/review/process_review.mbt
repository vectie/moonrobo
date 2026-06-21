///|
pub(all) enum ReviewSeverity {
  Info
  Attention
  Critical
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum ReviewDisposition {
  Accepted
  NeedsHumanReview
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ProcessReview {
  review_id : String
  task_id : String
  session_id : String
  robot_id : @core.RobotId
  receipt_id : @core.ReceiptId
  disposition : ReviewDisposition
  severity : ReviewSeverity
  summary : String
  findings : Array[String]
  artifact_paths : Array[String]
  created_at_ms : Int64
  resolved_at_ms : Int64?
  resolution_note : String?
} derive(Debug, Eq, ToJson, FromJson)

///|
fn replay_artifact_paths(replay : @replay.ReplayTimeline) -> Array[String] {
  let paths : Array[String] = []
  for frame in replay.frames {
    if frame.artifact_path != "" {
      paths.push(frame.artifact_path)
    }
  }
  paths
}

///|
fn append_if_not_empty(values : Array[String], value : String) -> Unit {
  if value != "" {
    values.push(value)
  }
}

///|
fn add_frame_findings(
  findings : Array[String],
  replay : @replay.ReplayTimeline,
) -> Unit {
  for frame in replay.frames {
    if frame.error_count > 0 {
      findings.push(
        "frame \{frame.frame_id} reported \{frame.error_count} telemetry errors",
      )
    }
  }
}

///|
fn severity_for_findings(findings : Array[String]) -> ReviewSeverity {
  if findings.is_empty() {
    Info
  } else {
    Attention
  }
}

///|
fn disposition_for_findings(findings : Array[String]) -> ReviewDisposition {
  if findings.is_empty() {
    Accepted
  } else {
    NeedsHumanReview
  }
}

///|
fn summary_for_findings(findings : Array[String]) -> String {
  if findings.is_empty() {
    "Observation run accepted with replay evidence"
  } else {
    "Observation run needs review: \{findings.length()} finding(s)"
  }
}

///|
pub fn diagnose_observation_run(
  plan : @task.ObservationTaskPlan,
  replay : @replay.ReplayTimeline,
  stop_receipt : @core.RunReceipt,
  receipt_path : String,
  observation_path : String,
  created_at_ms : Int64,
) -> ProcessReview {
  let findings : Array[String] = []
  if replay.status != "stopped" {
    findings.push("observation session is not stopped")
  }
  if replay.telemetry_frame_count != replay.frames.length() {
    findings.push(
      "telemetry frame count \{replay.telemetry_frame_count} does not match replay frame list \{replay.frames.length()}",
    )
  }
  if stop_receipt.status != Executed {
    findings.push("stop receipt was not executed")
  }
  add_frame_findings(findings, replay)
  let artifact_paths = replay_artifact_paths(replay)
  append_if_not_empty(artifact_paths, receipt_path)
  append_if_not_empty(artifact_paths, observation_path)
  {
    review_id: "review-\{plan.session_id}",
    task_id: plan.task_id,
    session_id: plan.session_id,
    robot_id: replay.robot_id,
    receipt_id: stop_receipt.receipt_id,
    disposition: disposition_for_findings(findings),
    severity: severity_for_findings(findings),
    summary: summary_for_findings(findings),
    findings,
    artifact_paths,
    created_at_ms,
    resolved_at_ms: None,
    resolution_note: None,
  }
}

///|
pub fn resolve_review(
  review : ProcessReview,
  note : String,
  resolved_at_ms : Int64,
) -> ProcessReview {
  {
    ..review,
    disposition: Accepted,
    severity: Info,
    summary: if note == "" {
      "Review accepted for next process"
    } else {
      "Review accepted: \{note}"
    },
    resolved_at_ms: Some(resolved_at_ms),
    resolution_note: if note == "" {
      None
    } else {
      Some(note)
    },
  }
}

///|
pub fn review_json(review : ProcessReview, indent? : Int = 2) -> String {
  review.to_json().stringify(indent~)
}
