///|
pub(all) struct RobotTaskMessageRequest {
  message_id : String
  robot_id : @core.RobotId
  requested_by : @core.Requester
  message : String
  now_ms : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RobotTaskMessagePlan {
  message_id : String
  task : RobotTaskRequest
  route : String
  reason : String
  classification : String
  physical_execution_allowed : Bool
  requires_review : Bool
  suggested_capability : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn task_message_request(
  message_id : String,
  robot_id : @core.RobotId,
  requested_by : @core.Requester,
  message : String,
  now_ms : Int64,
) -> RobotTaskMessageRequest {
  { message_id, robot_id, requested_by, message, now_ms }
}

///|
fn message_task_id(request : RobotTaskMessageRequest) -> String {
  if request.message_id == "" {
    "message-\{request.now_ms}"
  } else {
    "message-\{request.message_id}"
  }
}

///|
fn contains_observation_goal(text : String) -> Bool {
  contains_word(text, "observe") ||
  contains_word(text, "inspect") ||
  contains_word(text, "check") ||
  contains_word(text, "status") ||
  contains_word(text, "telemetry") ||
  contains_word(text, "look") ||
  contains_word(text, "watch")
}

///|
fn contains_physical_action(text : String) -> Bool {
  contains_word(text, "walk") ||
  contains_word(text, "run") ||
  contains_word(text, "move") ||
  contains_word(text, "stand") ||
  contains_word(text, "hold") ||
  contains_word(text, "execute") ||
  contains_word(text, "actuate") ||
  contains_word(text, "go") ||
  contains_word(text, "approach") ||
  contains_word(text, "bring") ||
  contains_word(text, "pick") ||
  contains_word(text, "grab")
}

///|
fn contains_maintenance_goal(text : String) -> Bool {
  contains_word(text, "charge") ||
  contains_word(text, "dock") ||
  contains_word(text, "battery") ||
  contains_word(text, "calibrate") ||
  contains_word(text, "maintenance") ||
  contains_word(text, "diagnose") ||
  contains_word(text, "repair") ||
  contains_word(text, "fault")
}

///|
fn normalize_words(message : String) -> String {
  message
  .to_lower()
  .replace(old=",", new=" ")
  .replace(old=".", new=" ")
  .replace(old="?", new=" ")
  .replace(old="!", new=" ")
  .replace(old=":", new=" ")
  .replace(old=";", new=" ")
}

///|
fn contains_word(text : String, word : String) -> Bool {
  (" " + text + " ").contains(" " + word + " ")
}

///|
fn physical_capability_hint(text : String) -> String {
  if contains_word(text, "run") {
    "control.high.run"
  } else if contains_word(text, "stand") || contains_word(text, "hold") {
    "control.high.hold"
  } else {
    "control.high.walk"
  }
}

///|
fn task_request(
  request : RobotTaskMessageRequest,
  kind : RobotTaskKind,
  goal : String,
) -> RobotTaskRequest {
  {
    task_id: message_task_id(request),
    robot_id: request.robot_id,
    kind,
    requested_by: request.requested_by,
    goal,
    now_ms: request.now_ms,
  }
}

///|
fn plan(
  request : RobotTaskMessageRequest,
  task : RobotTaskRequest,
  route : String,
  reason : String,
  classification : String,
  physical_execution_allowed : Bool,
  requires_review : Bool,
  suggested_capability : String,
) -> RobotTaskMessagePlan {
  {
    message_id: request.message_id,
    task,
    route,
    reason,
    classification,
    physical_execution_allowed,
    requires_review,
    suggested_capability,
  }
}

///|
pub fn plan_task_message(
  profile : @core.RobotProfile,
  request : RobotTaskMessageRequest,
) -> Result[RobotTaskMessagePlan, RobotTaskIssue] {
  let message = request.message.trim().to_owned()
  if message == "" {
    return Err(issue("empty-message", "task message must not be empty"))
  }
  let normalized = normalize_words(message)
  if !task_robot_matches(
      task_request(request, ObserveTelemetry, message),
      profile,
    ) {
    return Err(
      issue("robot-mismatch", "task robot does not match selected profile"),
    )
  }
  if contains_maintenance_goal(normalized) {
    let task = task_request(request, ReviewMaintenance, message)
    return Ok(
      plan(
        request, task, "/api/agent/work-queue", "message mapped to maintenance review task",
        "maintenance-review", false, true, "",
      ),
    )
  }
  if contains_physical_action(normalized) {
    let task = task_request(request, ReviewCommandIntent, message)
    return Ok(
      plan(
        request,
        task,
        "/api/intents/evaluate",
        "message mapped to command intent review; physical execution remains gated",
        "command-intent-review",
        false,
        true,
        physical_capability_hint(normalized),
      ),
    )
  }
  if !contains_observation_goal(normalized) {
    return Err(
      issue(
        "unsupported-message", "task message did not map to a supported robot task",
      ),
    )
  }
  let task = observe_task_request(
    message_task_id(request),
    request.robot_id,
    request.requested_by,
    message,
    request.now_ms,
  )
  match plan_observation_task(profile, task) {
    Ok(_) =>
      Ok({
        message_id: request.message_id,
        task,
        route: "/api/moontown/tasks/observe",
        reason: "message mapped to read-only observation task",
        classification: "observation",
        physical_execution_allowed: false,
        requires_review: false,
        suggested_capability: "observe.telemetry",
      })
    Err(task_issue) => Err(task_issue)
  }
}
