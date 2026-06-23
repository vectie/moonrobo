///|
pub(all) struct MoontownTaskSubmissionResponse {
  persisted : Bool
  plan : @task.ObservationTaskPlan
  observation : @pipeline.ObservationSubmission
  resident : @resident.ResidentRobotAgent
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoontownTaskMessageResponse {
  persisted : Bool
  message_path : String
  message_plan : @task.RobotTaskMessagePlan
  plan : @task.ObservationTaskPlan?
  observation : @pipeline.ObservationSubmission?
  resident : @resident.ResidentRobotAgent
  memory : MoonBookMemoryResponse
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonBookTaskMessageRecord {
  message_path : String
  plan : @task.RobotTaskMessagePlan
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonBookTaskMessageListResponse {
  message_count : Int
  messages : Array[MoonBookTaskMessageRecord]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn moontown_observe_task_path() -> String {
  "/api/moontown/tasks/observe"
}

///|
pub fn moontown_task_message_path() -> String {
  "/api/moontown/tasks/message"
}

///|
pub fn moonbook_task_messages_path() -> String {
  "/api/moonbook/task-messages"
}

///|
pub fn moonbook_task_message_path(task_id : String) -> String {
  "/api/moonbook/task-messages/\{task_id}"
}

///|
fn task_id_from_moonbook_task_message_path(path : String) -> String? {
  let prefix = moonbook_task_messages_path() + "/"
  if path.has_prefix(prefix) {
    let value = path[prefix.length():].to_owned()
    if value == "" {
      None
    } else {
      Some(value)
    }
  } else {
    None
  }
}

///|
fn decode_task_message_plan_text(
  path : String,
  text : String,
) -> Result[@task.RobotTaskMessagePlan, HostApiResponse] {
  let json = @json.parse(text) catch {
    _ =>
      return Err(
        error_response(
          500, "parse-task-message-plan", path, "failed to parse MoonBook task message plan",
        ),
      )
  }
  let plan : @task.RobotTaskMessagePlan = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          500, "decode-task-message-plan", path, "failed to decode MoonBook task message plan",
        ),
      )
  }
  Ok(plan)
}

///|
fn read_task_message_record(
  path : String,
  text : String,
) -> Result[MoonBookTaskMessageRecord, HostApiResponse] {
  match decode_task_message_plan_text(path, text) {
    Ok(plan) => Ok({ message_path: path, plan })
    Err(response) => Err(response)
  }
}

///|
fn task_message_records(
  root : String,
) -> Result[Array[MoonBookTaskMessageRecord], HostApiResponse] {
  let paths = match @runtime.list_moonbook_task_message_paths(root) {
    Ok(paths) => paths
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
  }
  let records : Array[MoonBookTaskMessageRecord] = []
  for path in paths {
    let text = match @runtime.read_moonbook_task_message_json_file(path) {
      Ok(text) => text
      Err(issue) =>
        return Err(error_response(500, issue.code, issue.path, issue.message))
    }
    match read_task_message_record(path, text) {
      Ok(record) => records.push(record)
      Err(response) => return Err(response)
    }
  }
  Ok(records)
}

///|
pub fn moonbook_task_messages_response(root : String) -> HostApiResponse {
  match task_message_records(root) {
    Ok(messages) =>
      json_response(
        200,
        { message_count: messages.length(), messages }.to_json(),
      )
    Err(response) => response
  }
}

///|
pub fn moonbook_task_message_response(
  root : String,
  path : String,
) -> HostApiResponse {
  let task_id = match task_id_from_moonbook_task_message_path(path) {
    Some(value) => value
    None =>
      return error_response(404, "not-found", path, "No task message route")
  }
  let file_path = @runtime.moonbook_task_message_path(root, task_id)
  let text = match @runtime.read_moonbook_task_message_json(root, task_id) {
    Ok(text) => text
    Err(issue) =>
      return error_response(404, issue.code, issue.path, issue.message)
  }
  match read_task_message_record(file_path, text) {
    Ok(record) => json_response(200, record.to_json())
    Err(response) => response
  }
}

///|
fn decode_robot_task_request(
  body : String,
  path : String,
) -> Result[@task.RobotTaskRequest, HostApiError] {
  let json = @json.parse(body) catch {
    _ =>
      return Err({
        code: "parse-robot-task",
        path,
        message: "failed to parse robot task JSON",
      })
  }
  let request : @task.RobotTaskRequest = @json.from_json(json) catch {
    _ =>
      return Err({
        code: "decode-robot-task",
        path,
        message: "failed to decode robot task contract",
      })
  }
  Ok(request)
}

///|
fn decode_task_message_request(
  body : String,
  path : String,
) -> Result[@task.RobotTaskMessageRequest, HostApiError] {
  let json = @json.parse(body) catch {
    _ =>
      return Err({
        code: "parse-task-message",
        path,
        message: "failed to parse task message JSON",
      })
  }
  let request : @task.RobotTaskMessageRequest = @json.from_json(json) catch {
    _ =>
      return Err({
        code: "decode-task-message",
        path,
        message: "failed to decode task message contract",
      })
  }
  Ok(request)
}

///|
fn resident_after_task(
  root : String,
  book : @runtime.LoadedRoboBook,
) -> @resident.ResidentRobotAgent {
  @resident.project(
    book,
    sidecar_status(book.profile, root),
    receipts_or_empty(root),
    observation_sessions_or_empty(root),
    reviews_or_empty(root),
  )
}

///|
fn write_task_message_plan(
  root : String,
  message_plan : @task.RobotTaskMessagePlan,
) -> Result[String, HostApiResponse] {
  match
    @runtime.write_moonbook_task_message_json(
      root,
      message_plan.task.task_id,
      message_plan.to_json().stringify(indent=2),
    ) {
    Ok(path) => Ok(path)
    Err(issue) =>
      Err(error_response(500, issue.code, issue.path, issue.message))
  }
}

///|
pub fn moontown_observe_task_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let request = match
    decode_robot_task_request(body, moontown_observe_task_path()) {
    Ok(request) => request
    Err(error) =>
      return error_response(400, error.code, error.path, error.message)
  }
  let book = match @runtime.load_robobook(root) {
    Ok(book) => book
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let plan = match @task.plan_observation_task(book.profile, request) {
    Ok(plan) => plan
    Err(issue) =>
      return error_response(
        400,
        issue.code,
        moontown_observe_task_path(),
        issue.message,
      )
  }
  let observation = match
    @pipeline.start_observation(root, {
      session_id: plan.session_id,
      receipt_id: plan.receipt_id,
      requester: plan.requester,
      now_ms: plan.planned_at_ms,
    }) {
    Ok(response) => response
    Err(error) => return pipeline_error_response(error)
  }
  json_response(
    200,
    {
      persisted: true,
      plan: @task.accepted_plan(plan),
      observation,
      resident: resident_after_task(root, book),
    }.to_json(),
  )
}

///|
pub fn moontown_task_message_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let request = match
    decode_task_message_request(body, moontown_task_message_path()) {
    Ok(request) => request
    Err(error) =>
      return error_response(400, error.code, error.path, error.message)
  }
  let book = match @runtime.load_robobook(root) {
    Ok(book) => book
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let message_plan = match @task.plan_task_message(book.profile, request) {
    Ok(plan) => plan
    Err(issue) =>
      return error_response(
        400,
        issue.code,
        moontown_task_message_path(),
        issue.message,
      )
  }
  let message_path = match write_task_message_plan(root, message_plan) {
    Ok(path) => path
    Err(response) => return response
  }
  if !(message_plan.task.kind is ObserveTelemetry) {
    let resident = resident_after_task(root, book)
    let memory = match persist_moonbook_memory(root, message_plan.task.now_ms) {
      Ok(response) => response
      Err(response) => return response
    }
    return json_response(
      200,
      {
        persisted: true,
        message_path,
        message_plan,
        plan: None,
        observation: None,
        resident,
        memory,
      }.to_json(),
    )
  }
  let plan = match
    @task.plan_observation_task(book.profile, message_plan.task) {
    Ok(plan) => plan
    Err(issue) =>
      return error_response(
        400,
        issue.code,
        moontown_task_message_path(),
        issue.message,
      )
  }
  let observation = match
    @pipeline.start_observation(root, {
      session_id: plan.session_id,
      receipt_id: plan.receipt_id,
      requester: plan.requester,
      now_ms: plan.planned_at_ms,
    }) {
    Ok(response) => response
    Err(error) => return pipeline_error_response(error)
  }
  let resident = resident_after_task(root, book)
  let memory = match persist_moonbook_memory(root, plan.planned_at_ms) {
    Ok(response) => response
    Err(response) => return response
  }
  json_response(
    200,
    {
      persisted: true,
      message_path,
      message_plan,
      plan: Some(@task.accepted_plan(plan)),
      observation: Some(observation),
      resident,
      memory,
    }.to_json(),
  )
}
