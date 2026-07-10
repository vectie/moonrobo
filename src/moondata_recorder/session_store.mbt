///|
pub fn recorder_session_path(root : String, session_id : String) -> String {
  root_path(root, "runs/recorders/" + session_id + ".json")
}

///|
fn decode_recorder_session(
  path : String,
) -> Result[RecorderSession, @moondata_store.MoonDataStoreIssue] {
  let text = @fsx.read_file_to_string(path) catch {
    _ =>
      return Err(
        recorder_issue(
          "read-recorder-session", path, "failed to read MoonData recorder session",
        ),
      )
  }
  let json = @json.parse(text) catch {
    _ =>
      return Err(
        recorder_issue(
          "parse-recorder-session", path, "failed to parse MoonData recorder session",
        ),
      )
  }
  let session : RecorderSession = @json.from_json(json) catch {
    _ =>
      return Err(
        recorder_issue(
          "decode-recorder-session", path, "failed to decode MoonData recorder session contract",
        ),
      )
  }
  Ok(session)
}

///|
fn recover_recorder_session(
  path : String,
) -> Result[RecorderSession, @moondata_store.MoonDataStoreIssue] {
  match decode_recorder_session(path) {
    Ok(session) => Ok(session)
    Err(current_error) => {
      for candidate in [path + ".next", path + ".previous"] {
        if @fsx.path_exists(candidate) {
          match decode_recorder_session(candidate) {
            Ok(session) => return Ok(session)
            Err(_) => ()
          }
        }
      }
      Err(current_error)
    }
  }
}

///|
fn write_recorder_text(
  path : String,
  text : String,
) -> Result[Unit, @moondata_store.MoonDataStoreIssue] {
  @fsx.write_string_to_file(path, text) catch {
    _ =>
      return Err(
        recorder_issue(
          "write-recorder-session", path, "failed to persist MoonData recorder session",
        ),
      )
  }
  Ok(())
}

///|
pub fn write_recorder_session(
  root : String,
  session : RecorderSession,
) -> Result[String, @moondata_store.MoonDataStoreIssue] {
  if !safe_session_id(session.session_id) {
    return Err(
      recorder_issue(
        "recorder-session-id-unsafe",
        session.session_id,
        "recorder session id must be a path-safe local identifier",
      ),
    )
  }
  match @moondata_store.initialize_root(root) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let path = recorder_session_path(root, session.session_id)
  let next_path = path + ".next"
  let previous_path = path + ".previous"
  let body = session.to_json().stringify(indent=2)
  match write_recorder_text(next_path, body) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match decode_recorder_session(next_path) {
    Ok(staged) =>
      if staged != session {
        return Err(
          recorder_issue(
            "verify-recorder-session", next_path, "staged MoonData recorder session changed during serialization",
          ),
        )
      }
    Err(error) => return Err(error)
  }
  if @fsx.path_exists(path) {
    let current = @fsx.read_file_to_string(path) catch { _ => "" }
    if current != "" {
      match write_recorder_text(previous_path, current) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
    }
  }
  match write_recorder_text(path, body) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if @fsx.path_exists(next_path) {
    @fsx.remove_file(next_path) catch {
      _ => ()
    }
  }
  Ok(path)
}

///|
pub fn read_recorder_session(
  root : String,
  session_id : String,
) -> Result[RecorderSession, @moondata_store.MoonDataStoreIssue] {
  if !safe_session_id(session_id) {
    return Err(
      recorder_issue(
        "recorder-session-id-unsafe", session_id, "recorder session id must be a path-safe local identifier",
      ),
    )
  }
  recover_recorder_session(recorder_session_path(root, session_id))
}

///|
pub fn list_recorder_sessions(
  root : String,
) -> Result[Array[RecorderSession], @moondata_store.MoonDataStoreIssue] {
  match @moondata_store.initialize_root(root) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let dir = root_path(root, "runs/recorders")
  let names = @fsx.read_dir(dir) catch {
    _ =>
      return Err(
        recorder_issue(
          "list-recorder-sessions", dir, "failed to list MoonData recorder sessions",
        ),
      )
  }
  let sessions : Array[RecorderSession] = []
  for name in names {
    if name.has_suffix(".json") {
      match recover_recorder_session(dir + "/" + name) {
        Ok(session) => sessions.push(session)
        Err(_) => continue
      }
    }
  }
  Ok(sessions)
}
