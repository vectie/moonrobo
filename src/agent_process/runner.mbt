///|
pub(all) enum AgentProcessOutcome {
  Observed
  ReviewRequired
  Held
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct AgentProcessRunRequest {
  task_id : String
  goal : String
  now_ms : Int64
  frame_count : Int
  frame_interval_ms : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct AgentProcessRunResult {
  persisted : Bool
  outcome : AgentProcessOutcome
  message : String
  planning : @moonclaw.MoonClawPlanningResult
  observation_run : @pipeline.ObservationRunResult?
  reviews : Array[@review.ProcessReview]
  resident : @resident.ResidentRobotAgent
} derive(Debug, Eq, ToJson, FromJson)

///|
fn issue(
  http_status : Int,
  code : String,
  path : String,
  message : String,
) -> @pipeline.PipelineIssue {
  { http_status, code, path, message }
}

///|
fn runtime_issue(
  status : Int,
  error : @runtime.RuntimeIssue,
) -> @pipeline.PipelineIssue {
  issue(status, error.code, error.path, error.message)
}

///|
fn sidecar_spec(
  profile : @core.RobotProfile,
  root : String,
) -> @bridge_sidecar.BridgeSidecarSpec {
  @bridge_sidecar.spec_for_profile(profile, root)
}

///|
fn command_available(command : Array[String]) -> Bool {
  !command.is_empty() && @fsx.path_exists(command[0])
}

///|
fn sidecar_status(
  profile : @core.RobotProfile,
  root : String,
) -> @bridge_sidecar.BridgeSidecarStatus {
  let spec = sidecar_spec(profile, root)
  @bridge_sidecar.status_for_spec(spec, command_available(spec.command))
}

///|
fn list_receipts(
  root : String,
) -> Result[Array[@core.RunReceipt], @pipeline.PipelineIssue] {
  match @runtime.list_run_receipts(root) {
    Ok(receipts) => Ok(receipts)
    Err(error) => Err(runtime_issue(500, error))
  }
}

///|
fn list_observations(
  root : String,
) -> Result[Array[@core.ObservationSession], @pipeline.PipelineIssue] {
  match @runtime.list_observation_sessions(root) {
    Ok(sessions) => Ok(sessions)
    Err(error) => Err(runtime_issue(500, error))
  }
}

///|
fn list_reviews(
  root : String,
) -> Result[Array[@review.ProcessReview], @pipeline.PipelineIssue] {
  match @runtime.list_process_reviews(root) {
    Ok(reviews) => Ok(reviews)
    Err(error) => Err(runtime_issue(500, error))
  }
}

///|
fn list_task_executions(
  root : String,
) -> Result[Array[@core.TaskExecutionSnapshot], @pipeline.PipelineIssue] {
  let paths = match @runtime.list_task_execution_snapshot_paths(root) {
    Ok(paths) => paths
    Err(error) => return Err(runtime_issue(500, error))
  }
  let snapshots : Array[@core.TaskExecutionSnapshot] = []
  for path in paths {
    match @runtime.read_task_execution_snapshot_file(path) {
      Ok(snapshot) => snapshots.push(snapshot)
      Err(error) => return Err(runtime_issue(500, error))
    }
  }
  Ok(snapshots)
}

///|
fn project_resident(
  book : @runtime.LoadedRoboBook,
  root : String,
  receipts : Array[@core.RunReceipt],
  observations : Array[@core.ObservationSession],
  reviews : Array[@review.ProcessReview],
  executions : Array[@core.TaskExecutionSnapshot],
) -> @resident.ResidentRobotAgent {
  @resident.project(
    book,
    sidecar_status(book.profile, root),
    receipts,
    observations,
    reviews,
    executions~,
  )
}

///|
fn planning_memory(
  robot_id : @core.RobotId,
  resident : @resident.ResidentRobotAgent,
  reviews : Array[@review.ProcessReview],
  generated_at_ms : Int64,
) -> @moonbook.MoonBookMemoryPack {
  let queue = @work_queue.project(
    robot_id,
    resident,
    reviews,
    [],
    [],
    [],
    generated_at_ms,
  )
  @moonbook.project(resident, reviews, queue, generated_at_ms)
}

///|
fn planning_registry(
  root : String,
  robot_id : @core.RobotId,
  generated_at_ms : Int64,
) -> Result[@tool_registry.ToolRegistry, @pipeline.PipelineIssue] {
  match @runtime.ensure_tool_registry(root, robot_id, generated_at_ms) {
    Ok(registry) => Ok(registry)
    Err(error) => Err(runtime_issue(500, error))
  }
}

///|
pub fn default_run_request(
  task_id? : String = "standing-goal-agent-process",
  goal? : String = "agentic bounded observation process",
  now_ms? : Int64 = 0L,
  frame_count? : Int = 3,
  frame_interval_ms? : Int64 = 1L,
) -> AgentProcessRunRequest {
  { task_id, goal, now_ms, frame_count, frame_interval_ms }
}

///|
fn review_required_result(
  planning : @moonclaw.MoonClawPlanningResult,
  reviews : Array[@review.ProcessReview],
  resident : @resident.ResidentRobotAgent,
) -> AgentProcessRunResult {
  {
    persisted: false,
    outcome: ReviewRequired,
    message: planning.plan.summary,
    planning,
    observation_run: None,
    reviews,
    resident,
  }
}

///|
fn held_result(
  planning : @moonclaw.MoonClawPlanningResult,
  reviews : Array[@review.ProcessReview],
  resident : @resident.ResidentRobotAgent,
) -> AgentProcessRunResult {
  {
    persisted: false,
    outcome: Held,
    message: planning.plan.summary,
    planning,
    observation_run: None,
    reviews,
    resident,
  }
}

///|
fn observed_result(
  planning : @moonclaw.MoonClawPlanningResult,
  run : @pipeline.ObservationRunResult,
  reviews : Array[@review.ProcessReview],
  resident : @resident.ResidentRobotAgent,
) -> AgentProcessRunResult {
  {
    persisted: run.persisted,
    outcome: Observed,
    message: "Observation process completed: \{run.plan.session_id}",
    planning,
    observation_run: Some(run),
    reviews,
    resident,
  }
}

///|
pub fn run_next(
  root : String,
  request : AgentProcessRunRequest,
) -> Result[AgentProcessRunResult, @pipeline.PipelineIssue] {
  let book = match @runtime.load_robobook(root) {
    Ok(book) => book
    Err(error) => return Err(runtime_issue(500, error))
  }
  match @runtime.ensure_process_dirs(root) {
    Ok(_) => ()
    Err(error) => return Err(runtime_issue(500, error))
  }
  let receipts = match list_receipts(root) {
    Ok(receipts) => receipts
    Err(error) => return Err(error)
  }
  let observations = match list_observations(root) {
    Ok(observations) => observations
    Err(error) => return Err(error)
  }
  let reviews = match list_reviews(root) {
    Ok(reviews) => reviews
    Err(error) => return Err(error)
  }
  let executions = match list_task_executions(root) {
    Ok(executions) => executions
    Err(error) => return Err(error)
  }
  let resident = project_resident(
    book, root, receipts, observations, reviews, executions,
  )
  let memory = planning_memory(
    book.profile.id,
    resident,
    reviews,
    request.now_ms,
  )
  let registry = match
    planning_registry(root, book.profile.id, request.now_ms) {
    Ok(registry) => registry
    Err(error) => return Err(error)
  }
  let planning = @moonclaw.planning_result(
    resident,
    reviews,
    memory,
    registry,
    request.now_ms,
  )
  match planning.plan.action {
    ReviewEvidence => Ok(review_required_result(planning, reviews, resident))
    Hold => Ok(held_result(planning, reviews, resident))
    Observe => {
      let run = match
        @pipeline.run_bounded_observation(root, {
          task_id: request.task_id,
          robot_id: "",
          requester: @core.moontown_requester("moonclaw"),
          goal: request.goal,
          now_ms: request.now_ms,
          frame_count: request.frame_count,
          frame_interval_ms: request.frame_interval_ms,
        }) {
        Ok(run) => run
        Err(error) => return Err(error)
      }
      let updated_reviews = match list_reviews(root) {
        Ok(reviews) => reviews
        Err(error) => return Err(error)
      }
      let updated_observations = match list_observations(root) {
        Ok(observations) => observations
        Err(error) => return Err(error)
      }
      let updated_receipts = match list_receipts(root) {
        Ok(receipts) => receipts
        Err(error) => return Err(error)
      }
      let updated_executions = match list_task_executions(root) {
        Ok(executions) => executions
        Err(error) => return Err(error)
      }
      let updated_resident = project_resident(
        book, root, updated_receipts, updated_observations, updated_reviews, updated_executions,
      )
      Ok(observed_result(planning, run, updated_reviews, updated_resident))
    }
  }
}
