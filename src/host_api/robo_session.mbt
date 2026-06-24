///|
pub(all) struct RoboSessionResponse {
  status : String
  has_task_message : Bool
  session : PlatformTaskLoopSession
  conversation : @moonbook.MoonBookConversationThread
  resident : @resident.ResidentRobotAgent
  mapping : @resident.DigitalPhysicalMapping
  execution_proof : PlatformTaskLoopExecutionProof
  decision : RoboDecisionResponse
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
fn session_status(
  has_task : Bool,
  mapping : @resident.DigitalPhysicalMapping,
  proof : PlatformTaskLoopExecutionProof,
) -> String {
  if task_loop_execution_verified(proof) {
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
    next_route: platform_task_loop_path(),
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
  proof : PlatformTaskLoopExecutionProof,
  latest_turn : RoboTurnResponse?,
) -> PlatformTaskLoopSession {
  let latest = task_loop_latest_turn(conversation, status.task_id)
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
      platform_task_loop_path()
    } else {
      status.next_route
    },
    dispatch_requested,
    dispatch_ready: status.stage == "ready-to-dispatch",
    execution_verified: task_loop_execution_verified(proof),
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
    task_loop_conversation(root, runtime_status, runtime_bridge_base_url) {
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
  let proof = match task_loop_execution_proof(root) {
    Ok(proof) => proof
    Err(response) => return response
  }
  let (latest_turn, turn_count) = match latest_robo_turn(root) {
    Ok(result) => result
    Err(response) => return response
  }
  let has_task = conversation.latest_task_id != ""
  let status = if has_task {
    match
      task_loop_task_message_record(
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
  let decision_response = robo_decision_response(root)
  if decision_response.status < 200 || decision_response.status >= 300 {
    return decision_response
  }
  let decision = match decode_decision(decision_response) {
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
      decision,
      latest_turn,
      turn_count,
      memory,
      message: "Robo session is projected from MoonBook task messages, RoboBook evidence, Moonrobo turn artifacts, and the current decision.",
    }.to_json(),
  )
}
