///|
pub(all) enum AgentProcessOutcome {
  Observed
  ReviewRequired
  RemediatedReadiness
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
  memory_persisted : Bool
  memory_path : String
  memory_pack_id : String
  memory_card_count : Int
  gateway : AgentProcessGatewayResult?
  planning : @moonclaw.MoonClawPlanningResult
  observation_run : @pipeline.ObservationRunResult?
  reviews : Array[@review.ProcessReview]
  resident : @resident.ResidentRobotAgent
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct AgentProcessMemoryResult {
  persisted : Bool
  memory_path : String
  pack_id : String
  card_count : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct AgentProcessGatewayResult {
  attempted : Bool
  http_method : String
  route : String
  status : Int
  evidence_path : String
  message : String
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
fn persist_memory(
  root : String,
  robot_id : @core.RobotId,
  resident : @resident.ResidentRobotAgent,
  reviews : Array[@review.ProcessReview],
  generated_at_ms : Int64,
) -> Result[AgentProcessMemoryResult, @pipeline.PipelineIssue] {
  let pack = planning_memory(robot_id, resident, reviews, generated_at_ms)
  let memory_path = match
    @runtime.write_moonbook_memory_json(
      root,
      pack.pack_id,
      @moonbook.memory_pack_json(pack),
    ) {
    Ok(path) => path
    Err(error) => return Err(runtime_issue(500, error))
  }
  Ok({
    persisted: true,
    memory_path,
    pack_id: pack.pack_id,
    card_count: pack.card_count,
  })
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
  memory : AgentProcessMemoryResult,
) -> AgentProcessRunResult {
  {
    persisted: false,
    outcome: ReviewRequired,
    message: planning.plan.summary,
    memory_persisted: memory.persisted,
    memory_path: memory.memory_path,
    memory_pack_id: memory.pack_id,
    memory_card_count: memory.card_count,
    gateway: None,
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
  memory : AgentProcessMemoryResult,
) -> AgentProcessRunResult {
  {
    persisted: false,
    outcome: Held,
    message: planning.plan.summary,
    memory_persisted: memory.persisted,
    memory_path: memory.memory_path,
    memory_pack_id: memory.pack_id,
    memory_card_count: memory.card_count,
    gateway: None,
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
  memory : AgentProcessMemoryResult,
) -> AgentProcessRunResult {
  {
    persisted: run.persisted,
    outcome: Observed,
    message: "Observation process completed: \{run.plan.session_id}",
    memory_persisted: memory.persisted,
    memory_path: memory.memory_path,
    memory_pack_id: memory.pack_id,
    memory_card_count: memory.card_count,
    gateway: None,
    planning,
    observation_run: Some(run),
    reviews,
    resident,
  }
}

///|
fn remediated_result(
  planning : @moonclaw.MoonClawPlanningResult,
  reviews : Array[@review.ProcessReview],
  resident : @resident.ResidentRobotAgent,
  memory : AgentProcessMemoryResult,
  gateway : AgentProcessGatewayResult,
) -> AgentProcessRunResult {
  {
    persisted: gateway.status >= 200 && gateway.status < 300,
    outcome: RemediatedReadiness,
    message: gateway.message,
    memory_persisted: memory.persisted,
    memory_path: memory.memory_path,
    memory_pack_id: memory.pack_id,
    memory_card_count: memory.card_count,
    gateway: Some(gateway),
    planning,
    observation_run: None,
    reviews,
    resident,
  }
}

///|
fn gateway_result(
  action : @readiness.ReadinessAction,
  status : Int,
  evidence_path : String,
  message : String,
) -> AgentProcessGatewayResult {
  {
    attempted: true,
    http_method: action.http_method,
    route: action.route,
    status,
    evidence_path,
    message,
  }
}

///|
fn next_gateway_action(
  planning : @moonclaw.MoonClawPlanningResult,
) -> @readiness.ReadinessAction? {
  let selected_route = match planning.plan.steps.get(0) {
    Some(step) => step.route
    None =>
      match planning.context.readiness_plan.next_action {
        Some(action) => action.route
        None => ""
      }
  }
  if selected_route != "" {
    for action in planning.context.readiness_plan.actions {
      if action.route == selected_route {
        return Some(action)
      }
    }
  }
  planning.context.readiness_plan.next_action
}

///|
fn execute_gateway_action(
  root : String,
  book : @runtime.LoadedRoboBook,
  request : AgentProcessRunRequest,
  planning : @moonclaw.MoonClawPlanningResult,
  resident : @resident.ResidentRobotAgent,
  reviews : Array[@review.ProcessReview],
) -> Result[AgentProcessGatewayResult, @pipeline.PipelineIssue] {
  let action = match next_gateway_action(planning) {
    Some(action) => action
    None =>
      return Ok({
        attempted: false,
        http_method: "",
        route: "",
        status: 204,
        evidence_path: "",
        message: "no readiness gateway action is pending",
      })
  }
  match action.route {
    "/api/moonbook/remember" => {
      let memory = match
        persist_memory(root, book.profile.id, resident, reviews, request.now_ms) {
        Ok(memory) => memory
        Err(error) => return Err(error)
      }
      Ok(
        gateway_result(
          action,
          200,
          memory.memory_path,
          "MoonClaw persisted MoonBook memory through the Moonrobo gateway",
        ),
      )
    }
    "/api/tools/registry" => {
      match planning_registry(root, book.profile.id, request.now_ms) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
      Ok(
        gateway_result(
          action,
          200,
          @runtime.tool_registry_path(root),
          "MoonClaw refreshed the bounded Moonrobo tool registry",
        ),
      )
    }
    "/api/runtime/validation/session" => {
      let validation = match
        @runtime.write_runtime_validation_session_from_latest_health(
          root,
          book.profile,
          request.now_ms,
          @runtime.default_runtime_validation_session_request(),
        ) {
        Ok(value) => value
        Err(error) => return Err(runtime_issue(500, error))
      }
      Ok(
        gateway_result(
          action,
          if validation.session.ready_for_live_sdk {
            200
          } else {
            409
          },
          validation.session_path,
          validation.session.message,
        ),
      )
    }
    _ =>
      Ok(
        gateway_result(
          action,
          409,
          action.route,
          "MoonClaw selected a gateway route that still requires operator or host execution",
        ),
      )
  }
}

///|
fn latest_execution_path(resident : @resident.ResidentRobotAgent) -> String {
  match resident.latest_execution {
    Some(execution) => "/api/moonrobo/executions#\{execution.snapshot_id}"
    None => ""
  }
}

///|
fn latest_proof_session_path(resident : @resident.ResidentRobotAgent) -> String {
  match resident.latest_proof_session {
    Some(session) => session.session_path
    None => ""
  }
}

///|
fn latest_robo_loop_path(resident : @resident.ResidentRobotAgent) -> String {
  match resident.latest_proof_session {
    Some(session) => session.latest_proof_path
    None => ""
  }
}

///|
fn planning_gateway_status(
  root : String,
  book : @runtime.LoadedRoboBook,
  resident : @resident.ResidentRobotAgent,
  memory : @moonbook.MoonBookMemoryPack,
  readiness : @readiness.PlatformReadinessReport,
  readiness_plan : @readiness.PlatformReadinessPlan,
) -> @gateway.MoonroboGatewayStatus {
  let loop_ready = resident.verified_execution_count > 0
  @gateway.project({
    root,
    robot_id: book.profile.id,
    bridge_id: book.profile.bridge.id,
    mapped: book.status.ready && resident.robot_id == book.profile.id,
    has_task_message: memory.cards.any(card => card.kind.contains("task")),
    session_stage: resident.availability,
    memory_card_count: memory.card_count,
    loop_ready,
    loop_percent: if loop_ready {
      100
    } else {
      33
    },
    loop_status: if loop_ready {
      "complete"
    } else {
      "incomplete"
    },
    live_readiness_status: if readiness.ready {
      "ready-for-proof-session"
    } else {
      "needs-runtime-validation"
    },
    physical_execution_allowed: false,
    can_submit_gateway_command: readiness.ready,
    latest_task_execution_path: latest_execution_path(resident),
    latest_gateway_command_path: "",
    latest_robo_loop_path: latest_robo_loop_path(resident),
    latest_proof_session_path: latest_proof_session_path(resident),
    proof_session_feedback_closed: false,
    proof_session_auto_feedback_success_count: 0,
    proof_session_latest_feedback_status: 0,
    proof_session_latest_feedback_message: "",
    next_method: match readiness_plan.next_action {
      Some(action) => action.http_method
      None => "POST"
    },
    next_route: match readiness_plan.next_action {
      Some(action) => action.route
      None => "/api/moonrobo/proof-session"
    },
    next_title: match readiness_plan.next_action {
      Some(action) => action.title
      None => "Run bounded proof session"
    },
  })
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
  let readiness = @readiness.report(root, book)
  let readiness_plan = @readiness.plan(readiness)
  let gateway = planning_gateway_status(
    root, book, resident, memory, readiness, readiness_plan,
  )
  let planning = @moonclaw.planning_result(
    resident,
    reviews,
    memory,
    registry,
    readiness,
    readiness_plan,
    gateway,
    request.now_ms,
  )
  match planning.plan.action {
    ReviewEvidence => {
      let persisted_memory = match
        persist_memory(root, book.profile.id, resident, reviews, request.now_ms) {
        Ok(memory) => memory
        Err(error) => return Err(error)
      }
      Ok(review_required_result(planning, reviews, resident, persisted_memory))
    }
    RemediateReadiness => {
      let gateway = match
        execute_gateway_action(root, book, request, planning, resident, reviews) {
        Ok(gateway) => gateway
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
      let persisted_memory = match
        persist_memory(
          root,
          updated_resident.robot_id,
          updated_resident,
          updated_reviews,
          request.now_ms,
        ) {
        Ok(memory) => memory
        Err(error) => return Err(error)
      }
      Ok(
        remediated_result(
          planning, updated_reviews, updated_resident, persisted_memory, gateway,
        ),
      )
    }
    RunRobotRoutine | RunProofSession | Hold => {
      let persisted_memory = match
        persist_memory(root, book.profile.id, resident, reviews, request.now_ms) {
        Ok(memory) => memory
        Err(error) => return Err(error)
      }
      Ok(held_result(planning, reviews, resident, persisted_memory))
    }
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
      let persisted_memory = match
        persist_memory(
          root,
          updated_resident.robot_id,
          updated_resident,
          updated_reviews,
          request.now_ms,
        ) {
        Ok(memory) => memory
        Err(error) => return Err(error)
      }
      Ok(
        observed_result(
          planning, run, updated_reviews, updated_resident, persisted_memory,
        ),
      )
    }
  }
}
