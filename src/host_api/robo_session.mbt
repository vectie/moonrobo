///|
pub(all) struct RoboSessionResponse {
  status : String
  has_task_message : Bool
  session : RoboSessionState
  conversation : @moonbook.MoonBookConversationThread
  resident : @resident.ResidentRobotAgent
  mapping : @resident.DigitalPhysicalMapping
  execution_proof : RoboExecutionProof
  handoff : RoboHandoffResponse
  latest_loop : RoboLoopSummaryResponse?
  loop_count : Int
  latest_turn : RoboTurnResponse?
  turn_count : Int
  memory : @moonbook.MoonBookMemoryPack
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn robo_session_path() -> String {
  "/api/moonrobo/session"
}

///|
fn latest_robo_turn(
  root : String,
) -> Result[(RoboTurnResponse?, Int), HostApiResponse] {
  let paths = match @runtime.list_robo_turn_paths(root) {
    Ok(paths) => paths
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
  }
  let mut latest : RoboTurnResponse? = None
  for path in paths {
    match read_robo_turn_file(path) {
      Ok(turn) => latest = Some(turn)
      Err(response) => return Err(response)
    }
  }
  Ok((latest, paths.length()))
}

///|
fn latest_robo_loop(
  root : String,
) -> Result[(RoboLoopSummaryResponse?, Int), HostApiResponse] {
  let paths = match @runtime.list_robo_loop_paths(root) {
    Ok(paths) => paths
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
  }
  let mut latest : RoboLoopSummaryResponse? = None
  for path in paths {
    match read_robo_loop_file(path) {
      Ok(loop_run) => latest = Some(summarize_robo_loop(loop_run))
      Err(response) => return Err(response)
    }
  }
  Ok((latest, paths.length()))
}

///|
fn session_status(
  has_task : Bool,
  mapping : @resident.DigitalPhysicalMapping,
  proof : RoboExecutionProof,
) -> String {
  if robo_execution_verified(proof) {
    "verified"
  } else if has_task {
    "active"
  } else if mapping.mapped {
    "mapped"
  } else {
    "unmapped"
  }
}

///|
fn empty_task_status(
  runtime_status : String,
  runtime_bridge_base_url : String,
) -> @moonbook.TaskMessageExecutionStatus {
  {
    task_id: "",
    message_id: "",
    classification: "none",
    stage: "no-task",
    summary: "No MoonBook task message has been submitted for this Robo session.",
    next_route: moonrobo_gateway_command_path(),
    message_path: "",
    requires_review: false,
    runtime_required: false,
    runtime_status,
    runtime_bridge_base_url,
    evaluated: false,
    dry_run_collected: false,
    approved: false,
    dispatched: false,
    executed: false,
    receipt_id: "",
    receipt_status: "missing",
    bridge_status: "missing",
    evidence_paths: [],
  }
}

///|
fn session_from_state(
  status : @moonbook.TaskMessageExecutionStatus,
  dispatch_requested : Bool,
  conversation : @moonbook.MoonBookConversationThread,
  resident : @resident.ResidentRobotAgent,
  mapping : @resident.DigitalPhysicalMapping,
  proof : RoboExecutionProof,
  latest_turn : RoboTurnResponse?,
) -> RoboSessionState {
  let latest = robo_session_latest_turn(conversation, status.task_id)
  let fallback_user = match latest_turn {
    Some(turn) => turn.message
    None => ""
  }
  let fallback_robo = match latest_turn {
    Some(turn) => turn.status
    None => status.summary
  }
  {
    session_id: "robo-session:\{resident.resident_id}",
    thread_id: conversation.thread_id,
    resident_id: resident.resident_id,
    mapping_id: mapping.mapping_id,
    robot_id: mapping.robot_id,
    bridge_id: mapping.bridge_id,
    task_id: status.task_id,
    latest_user_text: match latest {
      Some(turn) => turn.user_text
      None => fallback_user
    },
    latest_robo_text: match latest {
      Some(turn) => turn.robo_text
      None => fallback_robo
    },
    stage: status.stage,
    continuation_route: if status.next_route == "" && status.task_id == "" {
      moonrobo_gateway_command_path()
    } else {
      status.next_route
    },
    dispatch_requested,
    dispatch_ready: status.stage == "ready-to-dispatch",
    execution_verified: robo_execution_verified(proof),
    recovery_kind: "",
    recovery_path: "",
  }
}

///|
pub fn robo_session_response(root : String) -> HostApiResponse {
  let book = match @runtime.load_robobook(root) {
    Ok(book) => book
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let (runtime_status, runtime_bridge_base_url) = latest_runtime_context(root)
  let conversation = match
    robo_session_conversation(root, runtime_status, runtime_bridge_base_url) {
    Ok(conversation) => conversation
    Err(response) => return response
  }
  let resident = resident_after_task(root, book)
  let mapping = @resident.digital_physical_mapping(
    book,
    resident,
    runtime_status~,
    runtime_bridge_base_url~,
  )
  let proof = match robo_execution_proof(root) {
    Ok(proof) => proof
    Err(response) => return response
  }
  let (latest_turn, turn_count) = match latest_robo_turn(root) {
    Ok(result) => result
    Err(response) => return response
  }
  let (latest_loop, loop_count) = match latest_robo_loop(root) {
    Ok(result) => result
    Err(response) => return response
  }
  let has_task = conversation.latest_task_id != ""
  let status = if has_task {
    match
      robo_session_task_message_record(
        root,
        conversation.latest_task_id,
        runtime_status,
        runtime_bridge_base_url,
      ) {
      Ok(record) => record.status
      Err(response) => return response
    }
  } else {
    empty_task_status(runtime_status, runtime_bridge_base_url)
  }
  let memory = match moonbook_memory_pack(root, 0L) {
    Ok(memory) => memory
    Err(response) => return response
  }
  let handoff_response = robo_handoff_response(root)
  if handoff_response.status < 200 || handoff_response.status >= 300 {
    return handoff_response
  }
  let handoff = match decode_handoff(handoff_response) {
    Ok(value) => value
    Err(response) => return response
  }
  let session = session_from_state(
    status, false, conversation, resident, mapping, proof, latest_turn,
  )
  json_response(
    200,
    RoboSessionResponse::{
      status: session_status(has_task, mapping, proof),
      has_task_message: has_task,
      session,
      conversation,
      resident,
      mapping,
      execution_proof: proof,
      handoff,
      latest_loop,
      loop_count,
      latest_turn,
      turn_count,
      memory,
      message: "Robo session is projected from MoonBook task messages, RoboBook evidence, Moonrobo loop/turn artifacts, and the current MoonClaw handoff state.",
    }.to_json(),
  )
}
