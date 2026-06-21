///|
pub(all) struct MoontownTaskSubmissionResponse {
  persisted : Bool
  plan : @task.ObservationTaskPlan
  observation : @pipeline.ObservationSubmission
  resident : @resident.ResidentRobotAgent
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn moontown_observe_task_path() -> String {
  "/api/moontown/tasks/observe"
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
fn resident_after_task(
  root : String,
  book : @runtime.LoadedRobotBook,
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
  let book = match @runtime.load_robotbook(root) {
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
