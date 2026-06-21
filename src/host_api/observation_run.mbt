///|
pub(all) struct ObservationRunSubmissionResponse {
  persisted : Bool
  plan : @task.ObservationTaskPlan
  observation : @pipeline.ObservationSubmission
  frame_submissions : Array[@pipeline.ObservationFrameSubmission]
  stop : @pipeline.ObservationSubmission
  replay : @replay.ReplayTimeline
  review : @review.ProcessReview
  review_path : String
  resident : @resident.ResidentRobotAgent
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn moontown_observe_run_path() -> String {
  "/api/moontown/tasks/observe-run"
}

///|
fn decode_observation_run_request(
  body : String,
  path : String,
) -> Result[@pipeline.ObservationRunRequest, HostApiError] {
  let json = @json.parse(body) catch {
    _ =>
      return Err({
        code: "parse-observation-run",
        path,
        message: "failed to parse observation run JSON",
      })
  }
  let request : @pipeline.ObservationRunRequest = @json.from_json(json) catch {
    _ =>
      return Err({
        code: "decode-observation-run",
        path,
        message: "failed to decode observation run contract",
      })
  }
  Ok(request)
}

///|
pub fn moontown_observe_run_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let path = moontown_observe_run_path()
  let request = match decode_observation_run_request(body, path) {
    Ok(request) => request
    Err(error) =>
      return error_response(400, error.code, error.path, error.message)
  }
  let run = match @pipeline.run_bounded_observation(root, request) {
    Ok(run) => run
    Err(error) => return pipeline_error_response(error)
  }
  let book = match @runtime.load_robotbook(root) {
    Ok(book) => book
    Err(error) =>
      return error_response(500, error.code, error.path, error.message)
  }
  json_response(
    200,
    {
      persisted: run.persisted,
      plan: run.plan,
      observation: run.observation,
      frame_submissions: run.frame_submissions,
      stop: run.stop,
      replay: run.replay,
      review: run.review,
      review_path: run.review_path,
      resident: resident_after_task(root, book),
    }.to_json(),
  )
}
