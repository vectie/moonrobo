///|
pub fn agent_work_queue_path() -> String {
  "/api/agent/work-queue"
}

///|
pub fn agent_next_action_path() -> String {
  "/api/agent/next-action"
}

///|
fn dataset_work_evidence_or_response(
  root : String,
  session : @core.ObservationSession,
) -> Result[@work_queue.DatasetWorkEvidence, HostApiResponse] {
  let episode = match build_dataset_episode(root, session.session_id) {
    Ok(episode) => episode
    Err(response) => return Err(response)
  }
  Ok(
    @work_queue.dataset_work_evidence(episode, @dataset.quality_report(episode)),
  )
}

///|
fn dataset_work_evidence_list(
  root : String,
  sessions : Array[@core.ObservationSession],
) -> Result[Array[@work_queue.DatasetWorkEvidence], HostApiResponse] {
  let evidence : Array[@work_queue.DatasetWorkEvidence] = []
  for session in sessions {
    if session.status == Stopped {
      match dataset_work_evidence_or_response(root, session) {
        Ok(value) => evidence.push(value)
        Err(response) => return Err(response)
      }
    }
  }
  Ok(evidence)
}

///|
fn project_agent_work_queue(
  root : String,
  generated_at_ms : Int64,
) -> Result[@work_queue.AgentWorkQueue, HostApiResponse] {
  let book = match @runtime.load_robotbook(root) {
    Ok(book) => book
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
  }
  let observations = observation_sessions_or_empty(root)
  let reviews = reviews_or_empty(root)
  let resident = resident_projection(
    book,
    sidecar_status(book.profile, root),
    root,
  )
  let evidence = match dataset_work_evidence_list(root, observations) {
    Ok(value) => value
    Err(response) => return Err(response)
  }
  Ok(
    @work_queue.project(
      book.profile.id,
      resident,
      reviews,
      evidence,
      policy_evaluations_or_empty(root),
      generated_at_ms,
    ),
  )
}

///|
pub fn agent_work_queue_response(root : String) -> HostApiResponse {
  match project_agent_work_queue(root, 0L) {
    Ok(queue) => json_response(200, queue.to_json())
    Err(response) => response
  }
}

///|
pub fn agent_next_action_response(root : String) -> HostApiResponse {
  match project_agent_work_queue(root, 0L) {
    Ok(queue) =>
      json_response(200, @work_queue.next_action_plan(queue).to_json())
    Err(response) => response
  }
}
