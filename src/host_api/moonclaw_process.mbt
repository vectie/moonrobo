///|
pub fn moonclaw_run_next_path() -> String {
  "/api/moonclaw/run-next"
}

///|
pub fn moonclaw_runs_path() -> String {
  "/api/moonclaw/runs"
}

///|
pub fn moonclaw_run_path(run_id : String) -> String {
  "/api/moonclaw/runs/\{run_id}"
}

///|
fn run_id_from_moonclaw_run_path(path : String) -> String? {
  let prefix = "/api/moonclaw/runs/"
  if path.has_prefix(prefix) && path.length() > prefix.length() {
    Some(path[prefix.length():path.length()].to_owned())
  } else {
    None
  }
}

///|
pub(all) struct AgentProcessRunListResponse {
  run_count : Int
  runs : Array[@agent_process.AgentProcessRunRecord]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct AgentProcessEvidenceSummary {
  run_id : String
  record_path : String
  outcome : @agent_process.AgentProcessOutcome
  action : @moonclaw.RobotProcessAction
  session_id : String
  replay_path : String
  telemetry_frame_count : Int
  latest_frame_id : String
  review_id : String
  review_path : String
  review_disposition : @review.ReviewDisposition
  artifact_paths : Array[String]
  memory_path : String
  memory_pack_id : String
  memory_card_count : Int
  gateway_route : String
  gateway_status : Int
  gateway_evidence_path : String
  gateway_message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct AgentProcessRunDetailResponse {
  run : @agent_process.AgentProcessRunRecord
  evidence : AgentProcessEvidenceSummary
} derive(Debug, Eq, ToJson, FromJson)

///|
fn optional_label(value : String?) -> String {
  match value {
    Some(text) => text
    None => "-"
  }
}

///|
fn process_review_path(review : @review.ProcessReview?) -> String {
  match review {
    Some(value) => review_path(value.review_id)
    None => "-"
  }
}

///|
fn latest_review(
  reviews : Array[@review.ProcessReview],
) -> @review.ProcessReview? {
  if reviews.is_empty() {
    None
  } else {
    Some(reviews[reviews.length() - 1])
  }
}

///|
fn evidence_summary(
  record : @agent_process.AgentProcessRunRecord,
) -> AgentProcessEvidenceSummary {
  let gateway = record.result.gateway
  match record.result.observation_run {
    Some(run) =>
      {
        run_id: record.run_id,
        record_path: record.record_path,
        outcome: record.result.outcome,
        action: record.result.planning.plan.action,
        session_id: run.plan.session_id,
        replay_path: replay_path(run.plan.session_id),
        telemetry_frame_count: run.replay.telemetry_frame_count,
        latest_frame_id: optional_label(run.replay.latest_frame_id),
        review_id: run.review.review_id,
        review_path: process_review_path(Some(run.review)),
        review_disposition: run.review.disposition,
        artifact_paths: run.review.artifact_paths,
        memory_path: record.result.memory_path,
        memory_pack_id: record.result.memory_pack_id,
        memory_card_count: record.result.memory_card_count,
        gateway_route: match gateway {
          Some(value) => value.route
          None => "-"
        },
        gateway_status: match gateway {
          Some(value) => value.status
          None => 0
        },
        gateway_evidence_path: match gateway {
          Some(value) => value.evidence_path
          None => "-"
        },
        gateway_message: match gateway {
          Some(value) => value.message
          None => "-"
        },
      }
    None => {
      let review = latest_review(record.result.reviews)
      {
        run_id: record.run_id,
        record_path: record.record_path,
        outcome: record.result.outcome,
        action: record.result.planning.plan.action,
        session_id: "-",
        replay_path: "-",
        telemetry_frame_count: 0,
        latest_frame_id: "-",
        review_id: match review {
          Some(value) => value.review_id
          None => "-"
        },
        review_path: process_review_path(review),
        review_disposition: match review {
          Some(value) => value.disposition
          None => Accepted
        },
        artifact_paths: match review {
          Some(value) => value.artifact_paths
          None => []
        },
        memory_path: record.result.memory_path,
        memory_pack_id: record.result.memory_pack_id,
        memory_card_count: record.result.memory_card_count,
        gateway_route: match gateway {
          Some(value) => value.route
          None => "-"
        },
        gateway_status: match gateway {
          Some(value) => value.status
          None => 0
        },
        gateway_evidence_path: match gateway {
          Some(value) => value.evidence_path
          None => "-"
        },
        gateway_message: match gateway {
          Some(value) => value.message
          None => "-"
        },
      }
    }
  }
}

///|
fn decode_agent_process_request(
  body : String,
  path : String,
) -> Result[@agent_process.AgentProcessRunRequest, HostApiError] {
  if body == "" {
    return Ok(@agent_process.default_run_request())
  }
  let json = @json.parse(body) catch {
    _ =>
      return Err({
        code: "parse-agent-process",
        path,
        message: "failed to parse agent process JSON",
      })
  }
  let request : @agent_process.AgentProcessRunRequest = @json.from_json(json) catch {
    _ =>
      return Err({
        code: "decode-agent-process",
        path,
        message: "failed to decode agent process contract",
      })
  }
  Ok(request)
}

///|
pub fn moonclaw_run_next_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let request = match
    decode_agent_process_request(body, moonclaw_run_next_path()) {
    Ok(request) => request
    Err(error) =>
      return error_response(400, error.code, error.path, error.message)
  }
  match @agent_process.run_next_recorded(root, request) {
    Ok(record) => json_response(200, record.to_json())
    Err(error) => pipeline_error_response(error)
  }
}

///|
pub fn moonclaw_runs_response(root : String) -> HostApiResponse {
  match @agent_process.list_agent_process_records(root) {
    Ok(records) =>
      json_response(
        200,
        { run_count: records.length(), runs: records }.to_json(),
      )
    Err(error) => pipeline_error_response(error)
  }
}

///|
pub fn moonclaw_run_response(root : String, path : String) -> HostApiResponse {
  let run_id = match run_id_from_moonclaw_run_path(path) {
    Some(value) => value
    None =>
      return error_response(
        404, "not-found", path, "No Moonrobo host API route",
      )
  }
  let record = match @agent_process.read_agent_process_record(root, run_id) {
    Ok(record) => record
    Err(error) => return pipeline_error_response(error)
  }
  json_response(
    200,
    { run: record, evidence: evidence_summary(record) }.to_json(),
  )
}
