///|
pub(all) struct MoonroboStatus {
  service : String
  robobook_root : String
  robot_id : @core.RobotId
  ready : Bool
  status : String
  bridge_state : String
  availability : String
  safety_state : String
  receipt_count : Int
  observation_count : Int
  process_review_count : Int
  policy_evaluation_count : Int
  pending_review_count : Int
  latest_session_id : String
  latest_review_id : String
  latest_policy_evaluation_id : String
  latest_policy_gate_status : String
  latest_policy_path : String
  latest_replay_path : String
  generated_at_ms : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
fn sidecar_state_text(state : @bridge_sidecar.SidecarState) -> String {
  match state {
    MissingCommand => "missing-command"
    Launchable => "launchable"
  }
}

///|
fn status_text(
  ready : Bool,
  resident : @resident.ResidentRobotAgent,
  sidecar : @bridge_sidecar.BridgeSidecarStatus,
) -> String {
  if !ready {
    "not-ready"
  } else if resident.review_count > 0 {
    "attention"
  } else if resident.availability == "observing" {
    "observing"
  } else if sidecar.state == MissingCommand {
    "degraded"
  } else {
    "healthy"
  }
}

///|
fn latest_session_id(resident : @resident.ResidentRobotAgent) -> String {
  match resident.latest_observation {
    Some(value) => value.session_id
    None => "-"
  }
}

///|
fn latest_replay_path(resident : @resident.ResidentRobotAgent) -> String {
  match resident.latest_observation {
    Some(value) => "/api/replays/\{value.session_id}"
    None => "-"
  }
}

///|
fn latest_review_id(reviews : Array[@review.ProcessReview]) -> String {
  if reviews.is_empty() {
    "-"
  } else {
    reviews[reviews.length() - 1].review_id
  }
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
fn latest_policy_evaluation_id(
  evaluations : Array[@policy.PolicyEvaluationReceipt],
) -> String {
  match latest_policy_evaluation(evaluations) {
    Some(value) => value.evaluation_id
    None => "-"
  }
}

///|
fn latest_policy_gate_status(
  evaluations : Array[@policy.PolicyEvaluationReceipt],
) -> String {
  match latest_policy_evaluation(evaluations) {
    Some(value) => value.gate_status
    None => "-"
  }
}

///|
fn latest_policy_path(
  evaluations : Array[@policy.PolicyEvaluationReceipt],
) -> String {
  match latest_policy_evaluation(evaluations) {
    Some(value) => "/api/policies/evaluations/\{value.evaluation_id}"
    None => "-"
  }
}

///|
pub fn project(
  book : @runtime.LoadedRoboBook,
  sidecar : @bridge_sidecar.BridgeSidecarStatus,
  resident : @resident.ResidentRobotAgent,
  receipts : Array[@core.RunReceipt],
  observations : Array[@core.ObservationSession],
  reviews : Array[@review.ProcessReview],
  policy_evaluations : Array[@policy.PolicyEvaluationReceipt],
  generated_at_ms : Int64,
) -> MoonroboStatus {
  {
    service: "moonrobo",
    robobook_root: book.root,
    robot_id: book.profile.id,
    ready: book.status.ready,
    status: status_text(book.status.ready, resident, sidecar),
    bridge_state: sidecar_state_text(sidecar.state),
    availability: resident.availability,
    safety_state: resident.safety_state,
    receipt_count: receipts.length(),
    observation_count: observations.length(),
    process_review_count: reviews.length(),
    policy_evaluation_count: policy_evaluations.length(),
    pending_review_count: resident.review_count,
    latest_session_id: latest_session_id(resident),
    latest_review_id: latest_review_id(reviews),
    latest_policy_evaluation_id: latest_policy_evaluation_id(policy_evaluations),
    latest_policy_gate_status: latest_policy_gate_status(policy_evaluations),
    latest_policy_path: latest_policy_path(policy_evaluations),
    latest_replay_path: latest_replay_path(resident),
    generated_at_ms,
  }
}

///|
pub fn status_json(status : MoonroboStatus, indent? : Int = 2) -> String {
  status.to_json().stringify(indent~)
}
