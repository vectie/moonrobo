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
  match @moondata_store.initialize_root(request.root) {
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
