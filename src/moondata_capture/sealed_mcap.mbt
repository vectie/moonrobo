///|
pub(all) struct SealMcapRequest {
  root : String
  source_path : String
  source_id : String
  capture_id : String
  dataset_id : String
  episode_id : String
  robot_id : String
  bridge_id : String
  session_id : String
  recorded_at_ms : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SealedMcapResult {
  root : String
  source_path : String
  format : String
  blob : @moondata_blob.LocalBlobResult
  capture : StoredCaptureRegistrationResult
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn seal_mcap_request(
  root : String,
  source_path : String,
  capture_id : String,
  robot_id : String,
  bridge_id : String,
  recorded_at_ms : Int64,
  source_id? : String = "",
  dataset_id? : String = "",
  episode_id? : String = "",
  session_id? : String = "",
) -> SealMcapRequest {
  {
    root,
    source_path,
    source_id: if source_id == "" {
      "source-\{capture_id}"
    } else {
      source_id
    },
    capture_id,
    dataset_id: if dataset_id == "" {
      "dataset-\{capture_id}"
    } else {
      dataset_id
    },
    episode_id: if episode_id == "" {
      "episode-\{capture_id}"
    } else {
      episode_id
    },
    robot_id,
    bridge_id,
    session_id: if session_id == "" {
      "session-\{capture_id}"
    } else {
      session_id
    },
    recorded_at_ms,
  }
}

///|
fn mcap_issue(
  code : String,
  path : String,
  message : String,
) -> @moondata_store.MoonDataStoreIssue {
  { code, path, message }
}

///|
fn capture_id_is_safe(id : String) -> Bool {
  id != "" && !id.contains("/") && !id.contains("\\") && id != "." && id != ".."
}

///|
fn validate_seal_ids(
  request : SealMcapRequest,
) -> Result[Unit, @moondata_store.MoonDataStoreIssue] {
  for
    id in [
      request.source_id,
      request.capture_id,
      request.dataset_id,
      request.episode_id,
      request.session_id,
    ] {
    if !capture_id_is_safe(id) {
      return Err(
        mcap_issue(
          "seal-capture-id-unsafe", id, "sealed capture ids must be non-empty path-safe identifiers",
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
fn validate_complete_mcap(
  path : String,
) -> Result[Unit, @moondata_store.MoonDataStoreIssue] {
  let size = match @moondata_blob.local_file_size(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if size < 16L {
    return Err(
      mcap_issue(
        "mcap-truncated", path, "MCAP capture is too short to contain opening and closing magic",
      ),
    )
  }
  let header = match @moondata_blob.read_local_file_range(path, 0L, 8) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !mcap_magic_matches(header) {
    return Err(
      mcap_issue(
        "mcap-header-invalid", path, "capture does not start with MCAP magic",
      ),
    )
  }
  let footer = match @moondata_blob.read_local_file_range(path, size - 8L, 8) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !mcap_magic_matches(footer) {
    return Err(
      mcap_issue(
        "mcap-not-finalized", path, "capture does not end with MCAP magic and must be recovered before sealing",
      ),
    )
  }
  Ok(())
}

///|
fn refs_match_checksum(
  refs : Array[@moondata_core.DataRef],
  checksum : String,
) -> Bool {
  for data_ref in refs {
    if data_ref.checksum == checksum {
      return true
    }
  }
  false
}

///|
fn seal_conflict(
  path : String,
) -> Result[Unit, @moondata_store.MoonDataStoreIssue] {
  Err(
    mcap_issue(
      "sealed-capture-conflict", path, "sealed capture identity already belongs to different content or provenance",
    ),
  )
}

///|
fn validate_existing_capture_identity(
  request : SealMcapRequest,
  checksum : String,
) -> Result[Unit, @moondata_store.MoonDataStoreIssue] {
  let source_path = @moondata_store.source_path(request.root, request.source_id)
  if @fsx.path_exists(source_path) {
    let source = match
      @moondata_store.read_source(request.root, request.source_id) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if source.kind != "mcap" ||
      source.robot_id != request.robot_id ||
      source.bridge_id != request.bridge_id ||
      source.origin_uri != "file://\{request.source_path}" ||
      source.created_at_ms != request.recorded_at_ms ||
      !refs_match_checksum(source.source_refs, checksum) {
      return seal_conflict(source_path)
    }
  }
  let capture_path = @moondata_store.capture_path(
    request.root,
    request.capture_id,
  )
  if @fsx.path_exists(capture_path) {
    let capture = match
      @moondata_store.read_capture(request.root, request.capture_id) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if capture.source_id != request.source_id ||
      capture.robot_id != request.robot_id ||
      capture.bridge_id != request.bridge_id ||
      capture.started_at_ms != request.recorded_at_ms ||
      capture.stopped_at_ms != Some(request.recorded_at_ms) ||
      !refs_match_checksum(capture.data_refs, checksum) {
      return seal_conflict(capture_path)
    }
  }
  let dataset_path = @moondata_store.dataset_kind_path(
    request.root,
    "raw",
    request.dataset_id,
  )
  if @fsx.path_exists(dataset_path) {
    let dataset = match
      @moondata_store.read_raw_dataset(request.root, request.dataset_id) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if dataset.kind != "raw" ||
      !dataset.source_ids.contains(request.source_id) ||
      !dataset.capture_ids.contains(request.capture_id) ||
      !dataset.episode_ids.contains(request.episode_id) ||
      dataset.created_at_ms != request.recorded_at_ms ||
      !refs_match_checksum(dataset.data_refs, checksum) {
      return seal_conflict(dataset_path)
    }
  }
  let episode_path = @moondata_store.episode_path(
    request.root,
    request.episode_id,
  )
  if @fsx.path_exists(episode_path) {
    let episode = match
      @moondata_store.read_episode(request.root, request.episode_id) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if episode.dataset_id != request.dataset_id ||
      episode.robot_id != request.robot_id ||
      episode.bridge_id != request.bridge_id ||
      episode.session_id != request.session_id ||
      episode.started_at_ms != request.recorded_at_ms ||
      !refs_match_checksum(episode.data_refs, checksum) {
      return seal_conflict(episode_path)
    }
  }
  let frame_id = "frame-\{request.capture_id}-recording"
  let frame_path = @moondata_store.frame_path(request.root, frame_id)
  if @fsx.path_exists(frame_path) {
    let frame = match @moondata_store.read_frame(request.root, frame_id) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    match frame.payload_ref {
      Some(data_ref) =>
        if frame.episode_id != request.episode_id ||
          frame.captured_at_ms != request.recorded_at_ms ||
          data_ref.checksum != checksum {
          return seal_conflict(frame_path)
        }
      None => return seal_conflict(frame_path)
    }
  }
  Ok(())
}

///|
pub fn seal_mcap_capture(
  request : SealMcapRequest,
) -> Result[SealedMcapResult, @moondata_store.MoonDataStoreIssue] {
  match validate_seal_ids(request) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match validate_complete_mcap(request.source_path) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let checksum = match @moondata_blob.local_file_checksum(request.source_path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match validate_existing_capture_identity(request, checksum) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let blob = match
    @moondata_blob.put_local_file(
      request.root,
      request.source_path,
      kind="mcap",
      content_type="application/x-mcap",
      expected_checksum=checksum,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let registration : @moondata_ingest.CaptureRegistrationRequest = {
    source_id: request.source_id,
    capture_id: request.capture_id,
    dataset_id: request.dataset_id,
    episode_id: request.episode_id,
    robot_id: request.robot_id,
    bridge_id: request.bridge_id,
    session_id: request.session_id,
    source_kind: "mcap",
    dataset_kind: "raw",
    source_label: "Sealed MCAP recording",
    origin_uri: "file://\{request.source_path}",
    status: "stopped",
    started_at_ms: request.recorded_at_ms,
    stopped_at_ms: Some(request.recorded_at_ms),
    receipt_ids: [],
    frames: [
      @moondata_ingest.frame_input(
        "frame-\{request.capture_id}-recording",
        request.recorded_at_ms,
        blob.uri,
        payload_kind="mcap",
        content_type="application/x-mcap",
        byte_count=blob.byte_count,
        checksum=blob.data_ref.checksum,
      ),
    ],
  }
  let capture = match
    register_stored_capture(
      stored_capture_registration_request(
        request.root,
        registration,
        generated_at_ms=request.recorded_at_ms,
      ),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    root: request.root,
    source_path: request.source_path,
    format: "mcap",
    blob,
    capture,
  })
}
