///|
pub(all) struct PlatformBootstrapStep {
  step_id : String
  status : String
  route : String
  artifact_path : String
  message : String
  physical_execution_allowed : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PlatformBootstrapResponse {
  persisted : Bool
  status : String
  before : @readiness.PlatformReadinessReport
  before_plan : @readiness.PlatformReadinessPlan
  after : @readiness.PlatformReadinessReport
  after_plan : @readiness.PlatformReadinessPlan
  steps : Array[PlatformBootstrapStep]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn platform_bootstrap_path() -> String {
  "/api/moonrobo/bootstrap"
}

///|
fn bootstrap_step(
  step_id : String,
  route : String,
  artifact_path : String,
  message : String,
) -> PlatformBootstrapStep {
  {
    step_id,
    status: "persisted",
    route,
    artifact_path,
    message,
    physical_execution_allowed: false,
  }
}

///|
fn default_bootstrap_task_message() -> @task.RobotTaskMessageRequest {
  @task.task_message_request(
    "bootstrap-first-task",
    "",
    @core.operator_requester("bootstrap"),
    "walk forward when ready",
    0L,
  )
}

///|
fn decode_platform_bootstrap_request(
  body : String,
) -> Result[@task.RobotTaskMessageRequest, HostApiResponse] {
  let submitted = body.trim().to_owned()
  if submitted == "" || submitted == "{}" {
    return Ok(default_bootstrap_task_message())
  }
  let json = @json.parse(submitted) catch {
    _ =>
      return Err(
        error_response(
          400,
          "parse-platform-bootstrap",
          platform_bootstrap_path(),
          "failed to parse platform bootstrap JSON",
        ),
      )
  }
  let request : @task.RobotTaskMessageRequest = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          400,
          "decode-platform-bootstrap",
          platform_bootstrap_path(),
          "failed to decode platform bootstrap task message",
        ),
      )
  }
  Ok(request)
}

///|
fn readiness_pair(
  root : String,
  book : @runtime.LoadedRoboBook,
) -> (@readiness.PlatformReadinessReport, @readiness.PlatformReadinessPlan) {
  let report = @readiness.report(root, book)
  (report, @readiness.plan(report))
}

///|
pub fn platform_bootstrap_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let request = match decode_platform_bootstrap_request(body) {
    Ok(request) => request
    Err(response) => return response
  }
  let book = match @runtime.load_robobook(root) {
    Ok(book) => book
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let (before, before_plan) = readiness_pair(root, book)
  let steps : Array[PlatformBootstrapStep] = []
  match @runtime.ensure_tool_registry(root, book.profile.id, request.now_ms) {
    Ok(_) =>
      steps.push(
        bootstrap_step(
          "persist-bounded-tool-registry",
          tool_registry_path(),
          @runtime.tool_registry_path(root),
          "bounded Moonrobo tool registry is persisted",
        ),
      )
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let message_plan = match @task.plan_task_message(book.profile, request) {
    Ok(plan) => plan
    Err(issue) =>
      return error_response(
        400,
        issue.code,
        platform_bootstrap_path(),
        issue.message,
      )
  }
  let message_path = match write_task_message_plan(root, message_plan) {
    Ok(path) => path
    Err(response) => return response
  }
  steps.push(
    bootstrap_step(
      "persist-first-task-message",
      moontown_task_message_path(),
      message_path,
      "first MoonBook task message is persisted for review",
    ),
  )
  let memory = match persist_moonbook_memory(root, request.now_ms) {
    Ok(response) => response
    Err(response) => return response
  }
  steps.push(
    bootstrap_step(
      "persist-moonbook-robot-memory",
      moonbook_remember_path(),
      memory.memory_path,
      "MoonBook memory is persisted from RoboBook evidence",
    ),
  )
  let (after, after_plan) = readiness_pair(root, book)
  json_response(
    200,
    {
      persisted: true,
      status: after.status,
      before,
      before_plan,
      after,
      after_plan,
      steps,
    }.to_json(),
  )
}
