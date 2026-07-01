///|
pub(all) struct StoredCaptureRegistrationRequest {
  root : String
  registration : @moondata_ingest.CaptureRegistrationRequest
  generated_at_ms : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct StoredCaptureRegistrationResult {
  root : String
  source_id : @moondata_core.SourceId
  capture_id : @moondata_core.CaptureId
  dataset_id : @moondata_core.DatasetId
  episode_id : @moondata_core.EpisodeId
  frame_count : Int
  catalog_path : String
  catalog_entry_count : Int
  registration : @moondata_ingest.CaptureRegistration
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn stored_capture_registration_request(
  root : String,
  registration : @moondata_ingest.CaptureRegistrationRequest,
  generated_at_ms? : Int64 = 0L,
) -> StoredCaptureRegistrationRequest {
  { root, registration, generated_at_ms }
}

///|
fn issue(
  code : String,
  path : String,
  message : String,
) -> @moondata_store.MoonDataStoreIssue {
  { code, path, message }
}

///|
fn id_is_path_safe(id : String) -> Bool {
  id != "" && !id.contains("/") && !id.contains("\\") && id != "." && id != ".."
}

///|
fn validate_id(
  id : String,
  code : String,
  label : String,
) -> Result[Unit, @moondata_store.MoonDataStoreIssue] {
  if !id_is_path_safe(id) {
    return Err(
      issue(code, id, "stored capture \{label} must be non-empty and path-safe"),
    )
  }
  Ok(())
}

///|
fn validate_registration_ids(
  registration : @moondata_ingest.CaptureRegistrationRequest,
) -> Result[Unit, @moondata_store.MoonDataStoreIssue] {
  match validate_id(registration.source_id, "invalid-source-id", "source id") {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match
    validate_id(registration.capture_id, "invalid-capture-id", "capture id") {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match
    validate_id(registration.dataset_id, "invalid-dataset-id", "dataset id") {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match
    validate_id(registration.episode_id, "invalid-episode-id", "episode id") {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  for frame in registration.frames {
    match validate_id(frame.frame_id, "invalid-frame-id", "frame id") {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  Ok(())
}

///|
fn relative_path_is_safe(relative : String) -> Bool {
  if relative == "" ||
    relative.has_prefix("/") ||
    relative.contains("\\") ||
    relative.contains("//") {
    return false
  }
  let parts = relative.split("/").to_array()
  for part in parts {
    if part == "" || part == "." || part == ".." {
      return false
    }
  }
  true
}

///|
fn payload_relative_path_is_allowed(relative : String) -> Bool {
  relative.has_prefix("media/imports/") ||
  relative.has_prefix("media/robot_models/") ||
  relative.has_prefix("media/replays/") ||
  relative.has_prefix("exports/")
}

///|
fn frame_payload_relative_path(uri : String) -> String? {
  match uri.strip_prefix("moondata://") {
    Some(relative) => {
      let path = relative.to_owned()
      if relative_path_is_safe(path) && payload_relative_path_is_allowed(path) {
        Some(path)
      } else {
        None
      }
    }
    None => None
  }
}

///|
fn validate_frame_payload_uris(
  registration : @moondata_ingest.CaptureRegistrationRequest,
) -> Result[Unit, @moondata_store.MoonDataStoreIssue] {
  for frame in registration.frames {
    match frame_payload_relative_path(frame.payload_uri) {
      Some(_) => ()
      None =>
        return Err(
          issue(
            "invalid-frame-payload-uri",
            frame.payload_uri,
            "stored capture frame payload_uri must be a path-safe moondata:// payload URI",
          ),
        )
    }
  }
  Ok(())
}

///|
fn validate_frame_payload_metadata(
  registration : @moondata_ingest.CaptureRegistrationRequest,
) -> Result[Unit, @moondata_store.MoonDataStoreIssue] {
  for frame in registration.frames {
    if frame.byte_count <= 0L || frame.checksum == "" {
      return Err(
        issue(
          "invalid-frame-payload-metadata",
          frame.payload_uri,
          "stored capture frame payloads must declare positive byte_count and checksum",
        ),
      )
    }
  }
  Ok(())
}

///|
fn join(root : String, relative : String) -> String {
  if root.has_suffix("/") {
    root + relative
  } else {
    root + "/" + relative
  }
}

///|
fn checksum_payload(
  path : String,
  expected_checksum : String,
  bytes : Bytes,
) -> Result[String, @moondata_store.MoonDataStoreIssue] {
  if expected_checksum.has_prefix("bytes-sum-v1:") {
    Ok(@moondata_core.bytes_checksum(bytes))
  } else {
    let text = @fsx.read_file_to_string(path) catch {
      _ =>
        return Err(
          issue(
            "frame-payload-unreadable", path, "stored capture frame payload must be readable for its declared checksum",
          ),
        )
    }
    Ok(@moondata_core.text_checksum(text))
  }
}

///|
fn validate_frame_payload_files(
  root : String,
  registration : @moondata_ingest.CaptureRegistrationRequest,
) -> Result[Unit, @moondata_store.MoonDataStoreIssue] {
  for frame in registration.frames {
    let relative = match frame_payload_relative_path(frame.payload_uri) {
      Some(value) => value
      None =>
        return Err(
          issue(
            "invalid-frame-payload-uri",
            frame.payload_uri,
            "stored capture frame payload_uri must be a path-safe moondata:// payload URI",
          ),
        )
    }
    let path = join(root, relative)
    if !@fsx.path_exists(path) {
      return Err(
        issue(
          "frame-payload-missing", path, "stored capture frame payload must exist before manifests are written",
        ),
      )
    }
    let bytes = @fsx.read_file_to_bytes(path) catch {
      _ =>
        return Err(
          issue(
            "frame-payload-unreadable", path, "stored capture frame payload must be readable before manifests are written",
          ),
        )
    }
    let actual_byte_count = bytes.length().to_int64()
    if frame.byte_count != actual_byte_count {
      return Err(
        issue(
          "frame-payload-byte-count-mismatch",
          path,
          "stored capture frame payload byte_count \{frame.byte_count} does not match payload length \{actual_byte_count}",
        ),
      )
    }
    let actual_checksum = match checksum_payload(path, frame.checksum, bytes) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if frame.checksum != actual_checksum {
      return Err(
        issue(
          "frame-payload-checksum-mismatch",
          path,
          "stored capture frame payload checksum \{frame.checksum} does not match \{actual_checksum}",
        ),
      )
    }
  }
  Ok(())
}

///|
fn write_frames(
  root : String,
  frames : Array[@moondata_core.FrameRef],
) -> Result[Unit, @moondata_store.MoonDataStoreIssue] {
  for frame in frames {
    match @moondata_store.write_frame(root, frame) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  Ok(())
}

///|
fn persist_registration(
  root : String,
  registration : @moondata_ingest.CaptureRegistration,
) -> Result[Unit, @moondata_store.MoonDataStoreIssue] {
  match @moondata_store.write_source(root, registration.source) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match @moondata_store.write_capture(root, registration.capture) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match @moondata_store.write_dataset(root, registration.dataset) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match @moondata_store.write_episode(root, registration.episode) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  write_frames(root, registration.frames)
}

///|
pub fn register_stored_capture(
  request : StoredCaptureRegistrationRequest,
) -> Result[StoredCaptureRegistrationResult, @moondata_store.MoonDataStoreIssue] {
  if request.registration.frames.length() == 0 {
    return Err(
      issue(
        "capture-empty",
        request.root,
        "stored capture registration requires at least one frame",
      ),
    )
  }
  match validate_registration_ids(request.registration) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match validate_frame_payload_uris(request.registration) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match validate_frame_payload_metadata(request.registration) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match @moondata_store.initialize_root(request.root) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match validate_frame_payload_files(request.root, request.registration) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let registration = @moondata_ingest.register_capture(request.registration)
  match persist_registration(request.root, registration) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let rebuild = match
    @moondata_index.rebuild_catalog(request.root, request.generated_at_ms) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    root: request.root,
    source_id: registration.source.source_id,
    capture_id: registration.capture.capture_id,
    dataset_id: registration.dataset.dataset_id,
    episode_id: registration.episode.episode_id,
    frame_count: registration.frames.length(),
    catalog_path: rebuild.catalog_path,
    catalog_entry_count: rebuild.entry_count,
    registration,
  })
}
