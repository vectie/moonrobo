///|
fn recorder_chunk_token(name : String) -> String {
  let checksum = @moondata_core.text_checksum(name)
  checksum[7:23].to_owned()
}

///|
pub fn seal_recorder_chunks(
  root : String,
  session_id : String,
  now_ms : Int64,
) -> Result[RecorderSealResult, @moondata_store.MoonDataStoreIssue] {
  let session = match read_recorder_session(root, session_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let process_may_own_chunks = session.status == "recording" ||
    session.status.has_prefix("stopping")
  if process_may_own_chunks && @native_process.is_running(session.pid) {
    return Err(
      recorder_issue(
        "recorder-session-active", session_id, "stop the recorder before sealing its MCAP chunks",
      ),
    )
  }
  let chunks = match discover_recorder_chunks(session.plan.output_dir) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let captures : Array[RecorderSealedChunk] = []
  let recovery_required_paths : Array[String] = []
  let invalid_paths : Array[String] = []
  for chunk in chunks {
    if chunk.finalized {
      let token = recorder_chunk_token(chunk.name)
      let capture_id = "capture-" + session_id + "-" + token
      let request = @moondata_capture.seal_mcap_request(
        root,
        chunk.path,
        capture_id,
        session.plan.robot_id,
        session.plan.bridge_id,
        session.started_at_ms,
        source_id="source-" + session_id + "-" + token,
        dataset_id="dataset-" + session_id + "-" + token,
        episode_id="episode-" + session_id + "-" + token,
        session_id~,
      )
      match @moondata_capture.seal_mcap_capture(request) {
        Ok(result) =>
          captures.push({
            name: chunk.name,
            path: chunk.path,
            capture_id: result.capture.capture_id,
            dataset_id: result.capture.dataset_id,
            episode_id: result.capture.episode_id,
            blob_uri: result.blob.uri,
            checksum: result.blob.data_ref.checksum,
            byte_count: result.blob.byte_count,
            existed: result.blob.existed,
          })
        Err(error) => return Err(error)
      }
    } else if chunk.recovery_required {
      recovery_required_paths.push(chunk.path)
    } else {
      invalid_paths.push(chunk.path)
    }
  }
  let status = if !recovery_required_paths.is_empty() ||
    !invalid_paths.is_empty() {
    "recovery-required"
  } else if captures.is_empty() {
    "stopped-empty"
  } else {
    "sealed"
  }
  let updated = {
    ..session,
    status,
    running: false,
    revision: session.revision + 1,
    updated_at_ms: now_ms,
    stopped_at_ms: if session.stopped_at_ms == 0L {
      now_ms
    } else {
      session.stopped_at_ms
    },
    chunks,
    message: if status == "sealed" {
      "all finalized recorder chunks are sealed into immutable raw captures"
    } else if status == "stopped-empty" {
      "recorder session has no MCAP chunks"
    } else {
      "some recorder chunks require recovery before sealing"
    },
  }
  match write_recorder_session(root, updated) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  Ok({
    schema_version: "moondata.recorder-seal.v1",
    session: updated,
    captures,
    sealed_count: captures.length(),
    recovery_required_paths,
    recovery_required_count: recovery_required_paths.length(),
    invalid_paths,
    invalid_count: invalid_paths.length(),
  })
}
