///|
pub fn source_json(source : DataSource, indent? : Int = 2) -> String {
  source.to_json().stringify(indent~)
}

///|
pub fn capture_json(capture : CaptureSession, indent? : Int = 2) -> String {
  capture.to_json().stringify(indent~)
}

///|
pub fn dataset_json(dataset : DatasetManifest, indent? : Int = 2) -> String {
  dataset.to_json().stringify(indent~)
}

///|
pub fn episode_json(episode : EpisodeManifest, indent? : Int = 2) -> String {
  episode.to_json().stringify(indent~)
}

///|
pub fn frame_json(frame : FrameRef, indent? : Int = 2) -> String {
  frame.to_json().stringify(indent~)
}

///|
pub fn quality_run_json(run : QualityRun, indent? : Int = 2) -> String {
  run.to_json().stringify(indent~)
}
