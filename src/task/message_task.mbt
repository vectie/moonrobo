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
  contains_word(text, "actuate")
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
pub fn plan_task_message(
  profile : @core.RobotProfile,
  request : RobotTaskMessageRequest,
) -> Result[RobotTaskMessagePlan, RobotTaskIssue] {
  let message = request.message.trim().to_owned()
  if message == "" {
    return Err(issue("empty-message", "task message must not be empty"))
  }
  let normalized = normalize_words(message)
  if contains_physical_action(normalized) {
    return Err(
      issue(
        "physical-action-message", "task messages may request observation only; physical action requires explicit command intent review",
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
      })
    Err(task_issue) => Err(task_issue)
  }
}
