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
      can_submit_gateway_command: live_status == "ready-for-proof-session" ||
      live_status == "verified",
      latest_task_execution_path: proof.latest_task_execution_path,
      latest_gateway_command_path: proof.latest_gateway_command_path,
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
fn routine_context_pack_for(
  root : String,
  now_ms : Int64,
) -> Result[@routine_context.RobotRoutineContextPack, HostApiResponse] {
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
  let platform_queue = match project_robot_platform_queue(root, now_ms) {
    Ok(queue) => queue
    Err(response) => return Err(response)
  }
  let readiness = @readiness.report(root, book)
  let readiness_plan = @readiness.plan(readiness)
  let gateway = match
    moonclaw_gateway_status_for_context(root, book, resident, memory) {
    Ok(status) => status
    Err(response) => return Err(response)
  }
  let task_intent = match latest_task_intent_for_context(root) {
    Ok(intent) => intent
    Err(response) => return Err(response)
  }
  Ok(
    @routine_context.routine_context(
      resident,
      reviews,
      memory,
      platform_queue,
      registry,
      readiness,
      readiness_plan,
      gateway,
      now_ms,
      task_intent~,
    ),
  )
}

///|
fn latest_task_intent_for_context(
  root : String,
) -> Result[@routine_context.RobotRoutineTaskIntent, HostApiResponse] {
  let (runtime_status, runtime_bridge_base_url) = latest_runtime_context(root)
  let conversation = match
    robo_session_conversation(root, runtime_status, runtime_bridge_base_url) {
    Ok(conversation) => conversation
    Err(response) => return Err(response)
  }
  let latest = match
    robo_session_latest_turn(conversation, conversation.latest_task_id) {
    Some(turn) => turn
    None => return Ok(@routine_context.empty_task_intent())
  }
  Ok(@routine_context.task_intent_from_turn(latest))
}
