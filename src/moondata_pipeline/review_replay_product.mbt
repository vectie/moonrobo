///|
priv struct ReviewReplayResult {
  annotation_set_id : @moondata_core.AnnotationSetId
  annotation_index_id : @moondata_core.AnnotationTargetIndexId
  replay_artifact_id : @moondata_core.ReplayArtifactId
  annotation_manifest : @moondata_store.PersistedManifest
  annotation_index_manifest : @moondata_store.PersistedManifest
  replay_manifest : @moondata_store.PersistedManifest
  replay_payload_ref : @moondata_core.DataRef
}

///|
fn write_review_replay(
  request : LocalFileProductRequest,
  version_id : String,
) -> Result[ReviewReplayResult, @moondata_store.MoonDataStoreIssue] {
  let review = match
    @moondata_review.materialize_stored_review(
      @moondata_review.stored_review_request(
        request.root,
        version_id,
        "moondata.pipeline",
        request.generated_at_ms + 4L,
        annotation_set_id=request.annotation_set_id,
        labels=[
          @moondata_core.annotation_label(
            "curation",
            "accepted",
            source="moondata.pipeline",
          ),
          @moondata_core.annotation_label(
            "split",
            "train",
            confidence=0.95,
            source="moondata.pipeline",
          ),
        ],
        summary="accepted local-file data product",
      ),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let replay = match
    @moondata_replay.materialize_stored_replay(
      @moondata_replay.stored_replay_request(
        request.root,
        version_id,
        request.generated_at_ms + 4L,
        replay_artifact_id=request.replay_artifact_id,
        summary="replayable local-file data product",
      ),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    annotation_set_id: review.annotation_set_id,
    annotation_index_id: review.annotation_index_id,
    replay_artifact_id: request.replay_artifact_id,
    annotation_manifest: review.annotation_manifest,
    annotation_index_manifest: review.annotation_index_manifest,
    replay_manifest: replay.replay_manifest,
    replay_payload_ref: replay.replay_payload_ref,
  })
}
