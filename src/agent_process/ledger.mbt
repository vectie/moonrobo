///|
pub(all) struct AgentProcessRunRecord {
  run_id : String
  request : AgentProcessRunRequest
  result : AgentProcessRunResult
  record_path : String
  created_at_ms : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
fn ledger_dir(root : String) -> String {
  @runtime.robobook_path(root, "runs/agent-process")
}

///|
fn ensure_ledger_dir(root : String) -> Result[Unit, @pipeline.PipelineIssue] {
  match @runtime.ensure_process_dirs(root) {
    Ok(_) => ()
    Err(error) => return Err(runtime_issue(500, error))
  }
  let dir = ledger_dir(root)
  if @fsx.path_exists(dir) {
    Ok(())
  } else {
    @fsx.create_dir(dir) catch {
      _ =>
        return Err(
          issue(
            500, "create-agent-process-dir", dir, "failed to create agent process ledger directory",
          ),
        )
    }
    Ok(())
  }
}

///|
pub fn run_id_for_request(request : AgentProcessRunRequest) -> String {
  "agent-process-\{request.task_id}-\{request.now_ms}"
}

///|
pub fn record_path(root : String, run_id : String) -> String {
  ledger_dir(root) + "/\{run_id}.json"
}

///|
pub fn record_json(record : AgentProcessRunRecord, indent? : Int = 2) -> String {
  record.to_json().stringify(indent~)
}

///|
fn write_record(
  root : String,
  record : AgentProcessRunRecord,
) -> Result[String, @pipeline.PipelineIssue] {
  match ensure_ledger_dir(root) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  @fsx.write_string_to_file(record.record_path, record_json(record)) catch {
    _ =>
      return Err(
        issue(
          500,
          "write-agent-process-record",
          record.record_path,
          "failed to write agent process record",
        ),
      )
  }
  Ok(record.record_path)
}

///|
pub fn run_next_recorded(
  root : String,
  request : AgentProcessRunRequest,
) -> Result[AgentProcessRunRecord, @pipeline.PipelineIssue] {
  let result = match run_next(root, request) {
    Ok(result) => result
    Err(error) => return Err(error)
  }
  let run_id = run_id_for_request(request)
  let path = record_path(root, run_id)
  let record = {
    run_id,
    request,
    result,
    record_path: path,
    created_at_ms: request.now_ms,
  }
  match write_record(root, record) {
    Ok(_) => Ok(record)
    Err(error) => Err(error)
  }
}

///|
fn read_record_file(
  path : String,
) -> Result[AgentProcessRunRecord, @pipeline.PipelineIssue] {
  let text = @fsx.read_file_to_string(path) catch {
    _ =>
      return Err(
        issue(
          500, "read-agent-process-record", path, "failed to read agent process record",
        ),
      )
  }
  let json = @json.parse(text) catch {
    _ =>
      return Err(
        issue(
          500, "parse-agent-process-record", path, "failed to parse agent process record JSON",
        ),
      )
  }
  let record : AgentProcessRunRecord = @json.from_json(json) catch {
    _ =>
      return Err(
        issue(
          500, "decode-agent-process-record", path, "failed to decode agent process record",
        ),
      )
  }
  Ok(record)
}

///|
pub fn read_agent_process_record(
  root : String,
  run_id : String,
) -> Result[AgentProcessRunRecord, @pipeline.PipelineIssue] {
  read_record_file(record_path(root, run_id))
}

///|
pub fn list_agent_process_record_paths(
  root : String,
) -> Result[Array[String], @pipeline.PipelineIssue] {
  let dir = ledger_dir(root)
  if !@fsx.path_exists(dir) {
    return Ok([])
  }
  let names = @fsx.read_dir(dir) catch {
    _ =>
      return Err(
        issue(
          500, "read-agent-process-records", dir, "failed to read agent process ledger directory",
        ),
      )
  }
  names.sort()
  let paths : Array[String] = []
  for name in names {
    if name.has_suffix(".json") {
      paths.push(ledger_dir(root) + "/\{name}")
    }
  }
  Ok(paths)
}

///|
pub fn list_agent_process_records(
  root : String,
) -> Result[Array[AgentProcessRunRecord], @pipeline.PipelineIssue] {
  let paths = match list_agent_process_record_paths(root) {
    Ok(paths) => paths
    Err(error) => return Err(error)
  }
  let records : Array[AgentProcessRunRecord] = []
  for path in paths {
    match read_record_file(path) {
      Ok(record) => records.push(record)
      Err(error) => return Err(error)
    }
  }
  Ok(records)
}
