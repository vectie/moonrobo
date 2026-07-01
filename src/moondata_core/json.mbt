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

///|
pub fn dataset_version_json(
  version : DatasetVersion,
  indent? : Int = 2,
) -> String {
  version.to_json().stringify(indent~)
}

///|
pub fn transform_run_json(run : TransformRun, indent? : Int = 2) -> String {
  run.to_json().stringify(indent~)
}

///|
pub fn annotation_set_json(set : AnnotationSet, indent? : Int = 2) -> String {
  set.to_json().stringify(indent~)
}

///|
pub fn annotation_target_index_json(
  index : AnnotationTargetIndex,
  indent? : Int = 2,
) -> String {
  index.to_json().stringify(indent~)
}

///|
pub fn replay_artifact_json(
  artifact : ReplayArtifact,
  indent? : Int = 2,
) -> String {
  artifact.to_json().stringify(indent~)
}

///|
pub fn export_manifest_json(
  manifest : ExportManifest,
  indent? : Int = 2,
) -> String {
  manifest.to_json().stringify(indent~)
}

///|
pub fn moondata_catalog_json(
  catalog : MoonDataCatalog,
  indent? : Int = 2,
) -> String {
  catalog.to_json().stringify(indent~)
}
