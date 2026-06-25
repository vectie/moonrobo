///|
pub(all) struct MoonClawRobotRoutineRequest {
  task_message : @task.RobotTaskMessageRequest
  max_steps : Int
  remember : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonClawRobotRoutineResponse {
  routine_id : String
  routine_path : String
  persisted : Bool
  status : String
  accepted : Bool
  advanced_count : Int
  blocked_count : Int
  task_id : String
  context_before : @moonclaw.MoonClawPlanningResult
  robo_loop : RoboLoopResponse
  context_after : @moonclaw.MoonClawPlanningResult
  memory : MoonBookMemoryResponse
  memory_updated : Bool
  next_route : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn moonclaw_robot_routine_path() -> String {
  "/api/moonclaw/robot-routine"
}

///|
fn bounded_robot_routine_steps(max_steps : Int) -> Int {
  if max_steps < 1 {
    1
  } else if max_steps > 12 {
    12
  } else {
    max_steps
  }
}

///|
fn decode_moonclaw_robot_routine_request(
  body : String,
) -> Result[MoonClawRobotRoutineRequest, HostApiResponse] {
  let json = @json.parse(body) catch {
    _ =>
      return Err(
        error_response(
          400,
          "parse-moonclaw-robot-routine",
          moonclaw_robot_routine_path(),
          "failed to parse MoonClaw robot routine JSON",
        ),
      )
  }
  let request : MoonClawRobotRoutineRequest = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          400,
          "decode-moonclaw-robot-routine",
          moonclaw_robot_routine_path(),
          "failed to decode MoonClaw robot routine contract",
        ),
      )
  }
  Ok({
    task_message: request.task_message,
    max_steps: bounded_robot_routine_steps(request.max_steps),
    remember: request.remember,
  })
}

///|
fn decode_robot_routine_loop(
  response : HostApiResponse,
) -> Result[RoboLoopResponse, HostApiResponse] {
  let json = @json.parse(response.body) catch { _ => return Err(response) }
  let result : RoboLoopResponse = @json.from_json(json) catch {
    _ => return Err(response)
  }
  Ok(result)
}

///|
fn memory_has_task_message(memory : @moonbook.MoonBookMemoryPack) -> Bool {
  memory.cards.any(card => card.kind.contains("task"))
}

///|
fn moonclaw_gateway_status_for_context(
  root : String,
  book : @runtime.LoadedRoboBook,
  resident : @resident.ResidentRobotAgent,
  memory : @moonbook.MoonBookMemoryPack,
) -> Result[@gateway.MoonroboGatewayStatus, HostApiResponse] {
  let proof = match platform_loop_proof(root) {
    Ok(proof) => proof
    Err(response) => return Err(response)
  }
  let runtime_session = latest_runtime_validation_session_evidence(root)
  let ready_for_live_sdk = match runtime_session {
    Some(session) => session.ready_for_live_sdk
    None => false
  }
  let calibration = latest_runtime_calibration_plan(root)
  let pending_revalidation = match calibration {
    Some(plan) => calibration_pending_revalidation(root, plan) is Some(_)
    None => false
  }
  let calibration_status = calibration_status_for_live_readiness(
    root, calibration, pending_revalidation,
  )
  let live_status = live_readiness_status(
    proof, ready_for_live_sdk, calibration_status,
  )
  let (next_method, next_route, next_title) = live_readiness_next(live_status)
  let latest_session = match latest_proof_session(root) {
    Ok((Some(session), _)) => Some(session)
    Ok((None, _)) => None
    Err(_) => None
  }
  let latest_session_path = match latest_session {
    Some(session) => session.session_path
    None => ""
  }
  Ok(
    @gateway.project({
      root,
      robot_id: book.profile.id,
      bridge_id: book.profile.bridge.id,
      mapped: book.status.ready && resident.robot_id == book.profile.id,
      has_task_message: memory_has_task_message(memory),
      session_stage: resident.availability,
      memory_card_count: memory.card_count,
      loop_ready: proof.ready,
      loop_percent: proof.percent,
      loop_status: proof.status,
      live_readiness_status: live_status,
      physical_execution_allowed: live_status == "verified",
      can_run_robot_routine: live_status == "ready-for-proof-session" ||
      live_status == "verified",
      latest_task_execution_path: proof.latest_task_execution_path,
      latest_routine_path: proof.latest_routine_path,
      latest_robo_loop_path: proof.latest_robo_loop_path,
      latest_proof_session_path: latest_session_path,
      proof_session_feedback_closed: match latest_session {
        Some(session) => session.auto_feedback_success_count > 0
        None => false
      },
      proof_session_auto_feedback_success_count: match latest_session {
        Some(session) => session.auto_feedback_success_count
        None => 0
      },
      proof_session_latest_feedback_status: match latest_session {
        Some(session) => session.latest_auto_feedback_status
        None => 0
      },
      proof_session_latest_feedback_message: match latest_session {
        Some(session) => session.latest_auto_feedback_message
        None => ""
      },
      next_method,
      next_route,
      next_title,
    }),
  )
}

///|
fn moonclaw_planning_result_for(
  root : String,
  now_ms : Int64,
) -> Result[@moonclaw.MoonClawPlanningResult, HostApiResponse] {
  let book = match @runtime.load_robobook(root) {
    Ok(book) => book
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
  }
  let reviews = reviews_or_empty(root)
  let resident = resident_projection(
    book,
    sidecar_status(book.profile, root),
    root,
  )
  let memory = match moonbook_memory_pack(root, now_ms) {
    Ok(pack) => pack
    Err(response) => return Err(response)
  }
  let registry = match tool_registry_or_response(root, now_ms) {
    Ok(registry) => registry
    Err(response) => return Err(response)
  }
  let readiness = @readiness.report(root, book)
  let readiness_plan = @readiness.plan(readiness)
  let gateway = match
    moonclaw_gateway_status_for_context(root, book, resident, memory) {
    Ok(status) => status
    Err(response) => return Err(response)
  }
  Ok(
    @moonclaw.planning_result(
      resident, reviews, memory, registry, readiness, readiness_plan, gateway, now_ms,
    ),
  )
}

///|
fn robot_routine_id(request : MoonClawRobotRoutineRequest) -> String {
  let base = if request.task_message.message_id == "" {
    "moonclaw-robot-routine-\{request.task_message.now_ms}"
  } else {
    "moonclaw-robot-routine-\{request.task_message.message_id}-\{request.task_message.now_ms}"
  }
  base
  .replace(old="/", new="-")
  .replace(old=":", new="-")
  .replace(old=" ", new="-")
}

///|
fn robot_routine_dir(root : String) -> String {
  @runtime.robobook_path(root, "runs/moonclaw-robot-routines")
}

///|
fn ensure_robot_routine_dir(root : String) -> Result[String, HostApiResponse] {
  match @runtime.ensure_process_dirs(root) {
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
    Ok(_) => ()
  }
  let dir = robot_routine_dir(root)
  if !@fsx.path_exists(dir) {
    @fsx.create_dir(dir) catch {
      _ =>
        return Err(
          error_response(
            500, "create-moonclaw-robot-routine-dir", dir, "failed to create MoonClaw robot routine directory",
          ),
        )
    }
  }
  Ok(dir)
}

///|
fn write_robot_routine_response(
  root : String,
  response : MoonClawRobotRoutineResponse,
) -> Result[String, HostApiResponse] {
  let dir = match ensure_robot_routine_dir(root) {
    Ok(dir) => dir
    Err(response) => return Err(response)
  }
  let path = dir + "/\{response.routine_id}.json"
  @fsx.write_string_to_file(path, response.to_json().stringify(indent=2)) catch {
    _ =>
      return Err(
        error_response(
          500, "write-moonclaw-robot-routine", path, "failed to persist MoonClaw robot routine artifact",
        ),
      )
  }
  Ok(path)
}

///|
fn robot_routine_loop_request(
  request : MoonClawRobotRoutineRequest,
) -> RoboLoopRequest {
  let now_ms = request.task_message.now_ms
  {
    loop_id: "loop-\{robot_routine_id(request)}",
    turn: Some({
      task_message: request.task_message,
      run_agent: false,
      max_steps: 1,
      now_ms,
      remember: request.remember,
    }),
    max_steps: request.max_steps,
    now_ms,
    remember: request.remember,
  }
}

///|
fn robot_routine_message(response : MoonClawRobotRoutineResponse) -> String {
  if response.accepted && response.blocked_count == 0 {
    "MoonClaw ran the robot routine through the canonical Moonrobo loop, persisted memory, and stopped at \{response.next_route}."
  } else if response.blocked_count > 0 {
    "MoonClaw ran the robot routine through the canonical Moonrobo loop and stopped with \{response.blocked_count} blocked step(s)."
  } else {
    "MoonClaw restored the canonical Moonrobo loop without accepting a new task message."
  }
}

///|
fn robot_routine_memory_card(
  response : MoonClawRobotRoutineResponse,
) -> @moonbook.MoonBookMemoryCard {
  @moonbook.memory_card(
    response.context_after.context.robot_id,
    response.context_after.context.resident.resident_id,
    "moonclaw-robot-routine",
    if response.blocked_count > 0 {
      88
    } else {
      58
    },
    "Latest MoonClaw robot routine",
    "MoonClaw routine \{response.routine_id} is \{response.status}; accepted \{response.accepted}; advanced \{response.advanced_count}; blocked \{response.blocked_count}; next \{response.next_route}",
    response.routine_path,
    response.next_route,
    response.context_after.context.generated_at_ms,
  )
}

///|
pub fn moonclaw_robot_routine_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let request = match decode_moonclaw_robot_routine_request(body) {
    Ok(request) => request
    Err(response) => return response
  }
  let context_before = match
    moonclaw_planning_result_for(root, request.task_message.now_ms) {
    Ok(result) => result
    Err(response) => return response
  }
  let loop_response = robo_loop_response(
    root,
    robot_routine_loop_request(request).to_json().stringify(),
  )
  let loop_run = match decode_robot_routine_loop(loop_response) {
    Ok(result) => result
    Err(response) => return response
  }
  let context_after = match
    moonclaw_planning_result_for(root, request.task_message.now_ms) {
    Ok(result) => result
    Err(response) => return response
  }
  let routine_id = robot_routine_id(request)
  let routine_path = robot_routine_dir(root) + "/\{routine_id}.json"
  let response : MoonClawRobotRoutineResponse = {
    routine_id,
    routine_path,
    persisted: true,
    status: loop_run.status,
    accepted: loop_run.accepted,
    advanced_count: loop_run.advanced_count,
    blocked_count: loop_run.blocked_count,
    task_id: match loop_run.turn {
      Some(turn) => turn.ask.task_id
      None => request.task_message.message_id
    },
    context_before,
    robo_loop: loop_run,
    context_after,
    memory: {
      persisted: false,
      memory_path: "",
      pack: context_after.context.memory,
    },
    memory_updated: request.remember,
    next_route: loop_run.decision.next_route,
    message: "",
  }
  let response = { ..response, message: robot_routine_message(response) }
  let memory = if request.remember {
    let routine_memory = robot_routine_memory_card(response)
    match
      persist_moonbook_memory_with_extra_cards(
        root,
        request.task_message.now_ms,
        [routine_memory],
      ) {
      Ok(memory) => memory
      Err(response) => return response
    }
  } else {
    { persisted: false, memory_path: "", pack: context_after.context.memory }
  }
  let response = { ..response, memory, }
  match write_robot_routine_response(root, response) {
    Ok(_) => json_response(loop_response.status, response.to_json())
    Err(error) => error
  }
}
