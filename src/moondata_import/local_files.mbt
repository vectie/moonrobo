///|
pub(all) struct LocalFileImportRequest {
  root : String
  input_dir : String
  dataset_id : @moondata_core.DatasetId
  robot_id : String
  bridge_id : String
  session_id : String
  imported_at_ms : Int64
  source_label : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ImportedPayload {
  source_path : String
  stored_path : String
  frame_id : @moondata_core.FrameId
  data_ref : @moondata_core.DataRef
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct LocalFileImportResult {
  root : String
  input_dir : String
  dataset_id : @moondata_core.DatasetId
  episode_id : @moondata_core.EpisodeId
  source_id : @moondata_core.SourceId
  capture_id : @moondata_core.CaptureId
  payload_count : Int
  catalog_path : String
  catalog_entry_count : Int
  payloads : Array[ImportedPayload]
  dataset : @moondata_core.DatasetManifest
  episode : @moondata_core.EpisodeManifest
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn local_file_import_request(
  root : String,
  input_dir : String,
  dataset_id : @moondata_core.DatasetId,
  robot_id : String,
  bridge_id : String,
  session_id : String,
  imported_at_ms : Int64,
  source_label? : String = "MoonData local file import",
) -> LocalFileImportRequest {
  {
    root,
    input_dir,
    dataset_id,
    robot_id,
    bridge_id,
    session_id,
    imported_at_ms,
    source_label,
  }
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
fn join(root : String, relative : String) -> String {
  if root.has_suffix("/") {
    root + relative
  } else {
    root + "/" + relative
  }
}

///|
fn ensure_dir(
  path : String,
) -> Result[Unit, @moondata_store.MoonDataStoreIssue] {
  if @fsx.path_exists(path) {
    return Ok(())
  }
  @fsx.create_dir(path) catch {
    _ =>
      return Err(
        issue("create-import-dir", path, "failed to create import directory"),
      )
  }
  Ok(())
}

///|
fn is_directory(path : String) -> Bool {
  @fsx.is_dir(path) catch {
    _ => false
  }
}

///|
fn content_type(name : String) -> String {
  if name.has_suffix(".json") {
    "application/json"
  } else if name.has_suffix(".jsonl") {
    "application/jsonl"
  } else if name.has_suffix(".csv") {
    "text/csv"
  } else if name.has_suffix(".txt") || name.has_suffix(".log") {
    "text/plain"
  } else {
    "application/octet-stream"
  }
}

///|
fn checksum(text : String) -> String {
  let modulo = 1000000007L
  let mut hash = 17L
  for char in text {
    hash = (hash * 257L + char.to_int().to_int64()) % modulo
  }
  "text-sum-v1:\{text.length()}:\{hash}"
}

///|
fn safe_char(char : Char) -> Char {
  if char.is_ascii_alphabetic() ||
    char.is_ascii_digit() ||
    char == '.' ||
    char == '-' ||
    char == '_' {
    char
  } else {
    '_'
  }
}

///|
fn safe_name(name : String) -> String {
  let out = StringBuilder()
  for char in name {
    out.write_char(safe_char(char))
  }
  let safe = out.to_string()
  if safe == "" {
    "payload"
  } else {
    safe
  }
}

///|
fn payload_dir(root : String, dataset_id : @moondata_core.DatasetId) -> String {
  join(root, "media/imports/\{dataset_id}")
}

///|
fn payload_uri(
  dataset_id : @moondata_core.DatasetId,
  stored_name : String,
) -> String {
  "moondata://media/imports/\{dataset_id}/\{stored_name}"
}

///|
fn frame_id(dataset_id : @moondata_core.DatasetId, index : Int) -> String {
  "frame-\{dataset_id}-import-\{index}"
}

///|
fn read_input_names(
  input_dir : String,
) -> Result[Array[String], @moondata_store.MoonDataStoreIssue] {
  if !@fsx.path_exists(input_dir) {
    return Err(
      issue("input-dir-missing", input_dir, "import input directory is missing"),
    )
  }
  if !is_directory(input_dir) {
    return Err(
      issue(
        "input-not-directory", input_dir, "import input path is not a directory",
      ),
    )
  }
  let names = @fsx.read_dir(input_dir) catch {
    _ =>
      return Err(
        issue("read-input-dir", input_dir, "failed to read input directory"),
      )
  }
  names.sort()
  Ok(names)
}

///|
fn import_payloads(
  request : LocalFileImportRequest,
) -> Result[Array[ImportedPayload], @moondata_store.MoonDataStoreIssue] {
  let base = payload_dir(request.root, request.dataset_id)
  match ensure_dir(join(request.root, "media/imports")) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match ensure_dir(base) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let names = match read_input_names(request.input_dir) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let payloads : Array[ImportedPayload] = []
  let mut sequence = 0
  for name in names {
    let source_path = join(request.input_dir, name)
    if !is_directory(source_path) {
      let text = @fsx.read_file_to_string(source_path) catch {
        _ =>
          return Err(
            issue(
              "read-input-file", source_path, "failed to read text import payload",
            ),
          )
      }
      let stored_name = "\{sequence}-\{safe_name(name)}"
      let stored_path = join(base, stored_name)
      @fsx.write_string_to_file(stored_path, text) catch {
        _ =>
          return Err(
            issue(
              "write-import-payload", stored_path, "failed to write MoonData import payload",
            ),
          )
      }
      let id = frame_id(request.dataset_id, sequence)
      payloads.push({
        source_path,
        stored_path,
        frame_id: id,
        data_ref: @moondata_core.data_ref(
          "payload-\{id}",
          "raw-file",
          payload_uri(request.dataset_id, stored_name),
          content_type=content_type(name),
          byte_count=text.length().to_int64(),
          checksum=checksum(text),
        ),
      })
      sequence += 1
    }
  }
  if payloads.length() == 0 {
    return Err(
      issue(
        "input-empty",
        request.input_dir,
        "import input directory has no readable file payloads",
      ),
    )
  }
  Ok(payloads)
}

///|
fn payload_refs(
  payloads : Array[ImportedPayload],
) -> Array[@moondata_core.DataRef] {
  let refs : Array[@moondata_core.DataRef] = []
  for payload in payloads {
    refs.push(payload.data_ref)
  }
  refs
}

///|
fn frame_ids(
  payloads : Array[ImportedPayload],
) -> Array[@moondata_core.FrameId] {
  let ids : Array[@moondata_core.FrameId] = []
  for payload in payloads {
    ids.push(payload.frame_id)
  }
  ids
}

///|
fn frames(
  request : LocalFileImportRequest,
  episode_id : @moondata_core.EpisodeId,
  payloads : Array[ImportedPayload],
) -> Array[@moondata_core.FrameRef] {
  let frames : Array[@moondata_core.FrameRef] = []
  for index in 0..<payloads.length() {
    let payload = payloads[index]
    frames.push(
      @moondata_core.frame_ref(
        payload.frame_id,
        episode_id,
        request.robot_id,
        request.bridge_id,
        index,
        request.imported_at_ms + index.to_int64(),
        payload_ref=Some(payload.data_ref),
      ),
    )
  }
  frames
}

///|
fn persist_import(
  request : LocalFileImportRequest,
  source : @moondata_core.DataSource,
  capture : @moondata_core.CaptureSession,
  dataset : @moondata_core.DatasetManifest,
  episode : @moondata_core.EpisodeManifest,
  frames : Array[@moondata_core.FrameRef],
) -> Result[Unit, @moondata_store.MoonDataStoreIssue] {
  match @moondata_store.write_source(request.root, source) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match @moondata_store.write_capture(request.root, capture) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match @moondata_store.write_dataset(request.root, dataset) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match @moondata_store.write_episode(request.root, episode) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  for frame in frames {
    match @moondata_store.write_frame(request.root, frame) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  Ok(())
}

///|
pub fn import_local_files(
  request : LocalFileImportRequest,
) -> Result[LocalFileImportResult, @moondata_store.MoonDataStoreIssue] {
  match @moondata_store.initialize_root(request.root) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let payloads = match import_payloads(request) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let source_id = "src-\{request.dataset_id}"
  let capture_id = "cap-\{request.dataset_id}"
  let episode_id = "ep-\{request.dataset_id}"
  let refs = payload_refs(payloads)
  let source = @moondata_core.data_source(
    source_id,
    "local-files",
    request.source_label,
    request.robot_id,
    request.bridge_id,
    "file://\{request.input_dir}",
    request.imported_at_ms,
    source_refs=refs,
  )
  let capture = @moondata_core.capture_session(
    capture_id,
    source_id,
    request.robot_id,
    request.bridge_id,
    "stopped",
    request.imported_at_ms,
    stopped_at_ms=Some(request.imported_at_ms),
    data_refs=refs,
  )
  let episode = @moondata_core.episode_manifest(
    episode_id,
    request.dataset_id,
    request.robot_id,
    request.bridge_id,
    request.session_id,
    "stopped",
    request.imported_at_ms,
    stopped_at_ms=Some(request.imported_at_ms),
    frame_count=payloads.length(),
    frame_ids=frame_ids(payloads),
    data_refs=refs,
  )
  let dataset = @moondata_core.dataset_manifest(
    request.dataset_id,
    "raw",
    "imported",
    request.imported_at_ms,
    source_ids=[source_id],
    capture_ids=[capture_id],
    episode_ids=[episode_id],
    data_refs=refs,
  )
  let frame_values = frames(request, episode_id, payloads)
  match
    persist_import(request, source, capture, dataset, episode, frame_values) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let rebuild = match
    @moondata_index.rebuild_catalog(request.root, request.imported_at_ms) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    root: request.root,
    input_dir: request.input_dir,
    dataset_id: request.dataset_id,
    episode_id,
    source_id,
    capture_id,
    payload_count: payloads.length(),
    catalog_path: rebuild.catalog_path,
    catalog_entry_count: rebuild.entry_count,
    payloads,
    dataset,
    episode,
  })
}
