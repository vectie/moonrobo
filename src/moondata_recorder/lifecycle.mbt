///|
fn ensure_output_dir(
  plan : RecorderPlan,
) -> Result[Unit, @moondata_store.MoonDataStoreIssue] {
  if !@fsx.path_exists(plan.output_dir) {
    @fsx.create_dir(plan.output_dir) catch {
      _ =>
        return Err(
          recorder_issue(
            "create-recorder-output",
            plan.output_dir,
            "failed to create MoonData recorder output directory",
          ),
        )
    }
  }
  Ok(())
}

///|
fn mcap_magic_matches(bytes : Bytes) -> Bool {
  let magic : Array[Byte] = [0x89, 0x4d, 0x43, 0x41, 0x50, 0x30, 0x0d, 0x0a]
  if bytes.length() != magic.length() {
    return false
  }
  for index in 0..<magic.length() {
    if bytes[index] != magic[index] {
      return false
    }
  }
  true
}

///|
fn inspect_recorder_chunk(
  name : String,
  path : String,
) -> Result[RecorderChunk, @moondata_store.MoonDataStoreIssue] {
  let size = match @moondata_blob.local_file_size(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let header_valid = if size >= 8L {
    match @moondata_blob.read_local_file_range(path, 0L, 8) {
      Ok(bytes) => mcap_magic_matches(bytes)
      Err(_) => false
    }
  } else {
    false
  }
  let finalized = if size >= 16L && header_valid {
    match @moondata_blob.read_local_file_range(path, size - 8L, 8) {
      Ok(bytes) => mcap_magic_matches(bytes)
      Err(_) => false
    }
  } else {
    false
  }
  Ok({
    name,
    path,
    byte_count: size,
    finalized,
    recovery_required: header_valid && !finalized,
  })
}

///|
pub fn discover_recorder_chunks(
  output_dir : String,
) -> Result[Array[RecorderChunk], @moondata_store.MoonDataStoreIssue] {
  if !@fsx.path_exists(output_dir) {
    return Ok([])
  }
  let names = @fsx.read_dir(output_dir) catch {
    _ =>
      return Err(
        recorder_issue(
          "list-recorder-output", output_dir, "failed to list MoonData recorder output",
        ),
      )
  }
  names.sort()
  let chunks : Array[RecorderChunk] = []
  for name in names {
    if name.has_suffix(".mcap") {
      match inspect_recorder_chunk(name, output_dir + "/" + name) {
        Ok(chunk) => chunks.push(chunk)
        Err(error) => return Err(error)
      }
    }
  }
  Ok(chunks)
}

///|
fn process_issue(
  path : String,
  error : @native_process.ProcessIssue,
) -> @moondata_store.MoonDataStoreIssue {
  recorder_issue(error.code, path, error.message)
}

///|
pub fn start_recorder(
  plan : RecorderPlan,
  now_ms : Int64,
) -> Result[RecorderSession, @moondata_store.MoonDataStoreIssue] {
  match @moondata_store.initialize_root(plan.root) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match ensure_output_dir(plan) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if @fsx.path_exists(recorder_session_path(plan.root, plan.session_id)) {
    let previous = match read_recorder_session(plan.root, plan.session_id) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if previous.running && @native_process.is_running(previous.pid) {
      return Err(
        recorder_issue(
          "recorder-session-active",
          plan.session_id,
          "recorder session already has a live process",
        ),
      )
    }
  }
  let available = match @moondata_blob.local_available_bytes(plan.root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if available < plan.minimum_free_bytes {
    return Err(
      recorder_issue(
        "recorder-disk-pressure",
        plan.root,
        "available disk capacity is below the recorder reserve",
      ),
    )
  }
  @fsx.write_string_to_file(plan.script_path, recorder_script(plan)) catch {
    _ =>
      return Err(
        recorder_issue(
          "write-recorder-script",
          plan.script_path,
          "failed to write MoonData recorder launch script",
        ),
      )
  }
  let process = match @native_process.start_shell_script(plan.script_path) {
    Ok(value) => value
    Err(error) => return Err(process_issue(plan.script_path, error))
  }
  let session : RecorderSession = {
    schema_version: "moondata.recorder-session.v2",
    session_id: plan.session_id,
    status: "recording",
    pid: process.pid,
    running: process.running,
    revision: 1,
    created_at_ms: now_ms,
    updated_at_ms: now_ms,
    started_at_ms: now_ms,
    stopped_at_ms: 0L,
    available_bytes: available,
    disk_pressure: false,
    message_loss_status: "not-observed",
    messages_lost: 0L,
    chunks: [],
    recoveries: [],
    plan,
    message: "ROS 2 MCAP recorder started",
  }
  match write_recorder_session(plan.root, session) {
    Ok(_) => Ok(session)
    Err(error) => {
      ignore(@native_process.stop(process.pid))
      Err(error)
    }
  }
}

///|
pub fn refresh_recorder(
  root : String,
  session_id : String,
  now_ms : Int64,
) -> Result[RecorderSession, @moondata_store.MoonDataStoreIssue] {
  let session = match read_recorder_session(root, session_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let running = @native_process.is_running(session.pid)
  let available = match @moondata_blob.local_available_bytes(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let chunks = match discover_recorder_chunks(session.plan.output_dir) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let disk_pressure = available < session.plan.minimum_free_bytes
  let mut status = session.status
  let mut message = session.message
  let mut stopped_at_ms = session.stopped_at_ms
  if running && disk_pressure {
    match @native_process.stop(session.pid) {
      Ok(_) => ()
      Err(error) => return Err(process_issue(session.plan.script_path, error))
    }
    status = "stopping-disk-pressure"
    message = "recorder stop requested because disk reserve was crossed"
  } else if !running && (status == "recording" || status.has_prefix("stopping")) {
    stopped_at_ms = now_ms
    if chunks.any(fn(chunk) { chunk.recovery_required }) {
      status = "interrupted"
      message = "recorder stopped with MCAP recovery required"
    } else {
      status = "stopped"
      message = "recorder process is not running"
    }
  }
  let refreshed = {
    ..session,
    status,
    running: running && !disk_pressure,
    revision: session.revision + 1,
    updated_at_ms: now_ms,
    stopped_at_ms,
    available_bytes: available,
    disk_pressure,
    chunks,
    message,
  }
  match write_recorder_session(root, refreshed) {
    Ok(_) => Ok(refreshed)
    Err(error) => Err(error)
  }
}

///|
pub fn stop_recorder(
  root : String,
  session_id : String,
  now_ms : Int64,
) -> Result[RecorderSession, @moondata_store.MoonDataStoreIssue] {
  let session = match read_recorder_session(root, session_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let running = @native_process.is_running(session.pid)
  if running {
    match @native_process.stop(session.pid) {
      Ok(_) => ()
      Err(error) => return Err(process_issue(session.plan.script_path, error))
    }
  }
  let chunks = match discover_recorder_chunks(session.plan.output_dir) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let stopped = {
    ..session,
    status: if running {
      "stopping"
    } else {
      "stopped"
    },
    running: false,
    revision: session.revision + 1,
    updated_at_ms: now_ms,
    stopped_at_ms: if running {
      0L
    } else {
      now_ms
    },
    chunks,
    message: if running {
      "recorder stop requested"
    } else {
      "recorder process was already stopped"
    },
  }
  match write_recorder_session(root, stopped) {
    Ok(_) => Ok(stopped)
    Err(error) => Err(error)
  }
}

///|
pub fn record_message_loss(
  root : String,
  session_id : String,
  messages_lost : Int64,
  now_ms : Int64,
) -> Result[RecorderSession, @moondata_store.MoonDataStoreIssue] {
  if messages_lost < 0L {
    return Err(
      recorder_issue(
        "recorder-loss-invalid", session_id, "message loss count cannot be negative",
      ),
    )
  }
  let session = match read_recorder_session(root, session_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let updated = {
    ..session,
    revision: session.revision + 1,
    updated_at_ms: now_ms,
    message_loss_status: if messages_lost > 0L {
      "observed"
    } else {
      "clear"
    },
    messages_lost,
  }
  match write_recorder_session(root, updated) {
    Ok(_) => Ok(updated)
    Err(error) => Err(error)
  }
}
