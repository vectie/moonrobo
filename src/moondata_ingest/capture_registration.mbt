///|
pub(all) struct CaptureFrameInput {
  frame_id : String
  captured_at_ms : Int64
  payload_uri : String
  payload_kind : String
  content_type : String
  byte_count : Int64
  checksum : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct CaptureRegistrationRequest {
  source_id : String
  capture_id : String
  dataset_id : String
  episode_id : String
  robot_id : String
  bridge_id : String
  session_id : String
  source_kind : String
  dataset_kind : String
  source_label : String
  origin_uri : String
  status : String
  started_at_ms : Int64
  stopped_at_ms : Int64?
  receipt_ids : Array[String]
  frames : Array[CaptureFrameInput]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct CaptureRegistration {
  source : @moondata_core.DataSource
  capture : @moondata_core.CaptureSession
  dataset : @moondata_core.DatasetManifest
  episode : @moondata_core.EpisodeManifest
  frames : Array[@moondata_core.FrameRef]
  refs : Array[@moondata_core.MoonDataRef]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn frame_input(
  frame_id : String,
  captured_at_ms : Int64,
  payload_uri : String,
  payload_kind? : String = "telemetry-frame",
  content_type? : String = "application/json",
  byte_count? : Int64 = 0L,
  checksum? : String = "",
) -> CaptureFrameInput {
  {
    frame_id,
    captured_at_ms,
    payload_uri,
    payload_kind,
    content_type,
    byte_count,
    checksum,
  }
}

///|
fn payload_ref(input : CaptureFrameInput) -> @moondata_core.DataRef {
  @moondata_core.data_ref(
    "payload-\{input.frame_id}",
    input.payload_kind,
    input.payload_uri,
    content_type=input.content_type,
    byte_count=input.byte_count,
    checksum=input.checksum,
  )
}

///|
fn build_frames(
  request : CaptureRegistrationRequest,
) -> Array[@moondata_core.FrameRef] {
  let frames : Array[@moondata_core.FrameRef] = []
  for index in 0..<request.frames.length() {
    let input = request.frames[index]
    frames.push(
      @moondata_core.frame_ref(
        input.frame_id,
        request.episode_id,
        request.robot_id,
        request.bridge_id,
        index,
        input.captured_at_ms,
        payload_ref=Some(payload_ref(input)),
      ),
    )
  }
  frames
}

///|
fn frame_ids(frames : Array[@moondata_core.FrameRef]) -> Array[String] {
  let ids : Array[String] = []
  for frame in frames {
    ids.push(frame.frame_id)
  }
  ids
}

///|
fn frame_payload_refs(
  frames : Array[@moondata_core.FrameRef],
) -> Array[@moondata_core.DataRef] {
  let refs : Array[@moondata_core.DataRef] = []
  for frame in frames {
    match frame.payload_ref {
      Some(value) => refs.push(value)
      None => ()
    }
  }
  refs
}

///|
pub fn register_capture(
  request : CaptureRegistrationRequest,
) -> CaptureRegistration {
  let frames = build_frames(request)
  let data_refs = frame_payload_refs(frames)
  let source = @moondata_core.data_source(
    request.source_id,
    request.source_kind,
    request.source_label,
    request.robot_id,
    request.bridge_id,
    request.origin_uri,
    request.started_at_ms,
    source_refs=data_refs,
  )
  let capture = @moondata_core.capture_session(
    request.capture_id,
    request.source_id,
    request.robot_id,
    request.bridge_id,
    request.status,
    request.started_at_ms,
    stopped_at_ms=request.stopped_at_ms,
    receipt_ids=request.receipt_ids,
    data_refs~,
  )
  let episode = @moondata_core.episode_manifest(
    request.episode_id,
    request.dataset_id,
    request.robot_id,
    request.bridge_id,
    request.session_id,
    request.status,
    request.started_at_ms,
    stopped_at_ms=request.stopped_at_ms,
    frame_count=frames.length(),
    frame_ids=frame_ids(frames),
    receipt_ids=request.receipt_ids,
    data_refs~,
  )
  let dataset = @moondata_core.dataset_manifest(
    request.dataset_id,
    request.dataset_kind,
    "active",
    request.started_at_ms,
    source_ids=[request.source_id],
    capture_ids=[request.capture_id],
    episode_ids=[request.episode_id],
    data_refs~,
  )
  {
    source,
    capture,
    dataset,
    episode,
    frames,
    refs: [
      @moondata_core.moondata_ref(
        "dataset",
        dataset.dataset_id,
        "",
        "registered \{dataset.kind} dataset",
      ),
      @moondata_core.moondata_ref(
        "episode",
        episode.episode_id,
        "",
        "registered capture episode",
      ),
    ],
  }
}
