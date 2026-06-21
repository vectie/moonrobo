///|
pub(all) enum RobotTaskKind {
  ObserveTelemetry
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum RobotTaskStatus {
  Planned
  Accepted
  Rejected
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RobotTaskRequest {
  task_id : String
  robot_id : @core.RobotId
  kind : RobotTaskKind
  requested_by : @core.Requester
  goal : String
  now_ms : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ObservationTaskPlan {
  task_id : String
  status : RobotTaskStatus
  capability : @core.CapabilityId
  session_id : String
  receipt_id : @core.ReceiptId
  requester : @core.Requester
  goal : String
  planned_at_ms : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RobotTaskIssue {
  code : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
fn issue(code : String, message : String) -> RobotTaskIssue {
  { code, message }
}

///|
pub fn observe_task_request(
  task_id : String,
  robot_id : @core.RobotId,
  requested_by : @core.Requester,
  goal : String,
  now_ms : Int64,
) -> RobotTaskRequest {
  { task_id, robot_id, kind: ObserveTelemetry, requested_by, goal, now_ms }
}

///|
fn task_robot_matches(
  request : RobotTaskRequest,
  profile : @core.RobotProfile,
) -> Bool {
  request.robot_id == "" || request.robot_id == profile.id
}

///|
pub fn plan_observation_task(
  profile : @core.RobotProfile,
  request : RobotTaskRequest,
) -> Result[ObservationTaskPlan, RobotTaskIssue] {
  if !task_robot_matches(request, profile) {
    return Err(
      issue("robot-mismatch", "task robot does not match selected profile"),
    )
  }
  if !@core.profile_supports(profile, "observe.telemetry") {
    return Err(
      issue(
        "unsupported-capability", "profile does not expose observe.telemetry",
      ),
    )
  }
  Ok({
    task_id: request.task_id,
    status: Planned,
    capability: "observe.telemetry",
    session_id: "task-\{request.task_id}-observe",
    receipt_id: "receipt-\{request.task_id}-observe",
    requester: request.requested_by,
    goal: request.goal,
    planned_at_ms: request.now_ms,
  })
}

///|
pub fn accepted_plan(plan : ObservationTaskPlan) -> ObservationTaskPlan {
  { ..plan, status: Accepted }
}

///|
pub fn plan_json(plan : ObservationTaskPlan, indent? : Int = 2) -> String {
  plan.to_json().stringify(indent~)
}
