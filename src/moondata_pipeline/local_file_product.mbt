///|
pub(all) struct LocalFileProductRequest {
  root : String
  input_dir : String
  dataset_id : String
  robot_id : String
  bridge_id : String
  generated_at_ms : Int64
  canonical_dataset_id : String
  quality_run_id : String
  curated_dataset_id : String
  version_id : String
  transform_run_id : String
  lineage_id : String
  annotation_set_id : String
  replay_artifact_id : String
  export_manifest_id : String
  target_format : String
  output_uri : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct LocalFileProductResult {
  root : String
  raw_dataset_id : String
  canonical_dataset_id : String
  quality_run_id : String
  curated_dataset_id : String
  version_id : String
  annotation_set_id : String
  replay_artifact_id : String
  export_manifest_id : String
  validation_report_id : String
  validation_status : String
  catalog_path : String
  catalog_entry_count : Int
  import_result : @moondata_import.LocalFileImportResult
  normalize_result : @moondata_normalize.NormalizeResult
  quality_result : @moondata_assess.DatasetQualityResult
  curation_result : @moondata_curate.StoredCurationResult
  annotation_manifest : @moondata_store.PersistedManifest
  replay_manifest : @moondata_store.PersistedManifest
  replay_payload_ref : @moondata_core.DataRef
  export_result : @moondata_publish.StoredExportResult
  validation_result : @moondata_validate.StoredValidationResult
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn local_file_product_request(
  root : String,
  input_dir : String,
  dataset_id : String,
  robot_id : String,
  bridge_id : String,
  generated_at_ms : Int64,
  canonical_dataset_id? : String = "",
  quality_run_id? : String = "",
  curated_dataset_id? : String = "",
  version_id? : String = "",
  transform_run_id? : String = "",
  lineage_id? : String = "",
  annotation_set_id? : String = "",
  replay_artifact_id? : String = "",
  export_manifest_id? : String = "",
  target_format? : String = "jsonl",
  output_uri? : String = "",
) -> LocalFileProductRequest {
  let canonical_id = if canonical_dataset_id == "" {
    "\{dataset_id}-canonical"
  } else {
    canonical_dataset_id
  }
  let quality_id = if quality_run_id == "" {
    "qr-\{canonical_id}"
  } else {
    quality_run_id
  }
  let curated_id = if curated_dataset_id == "" {
    "\{canonical_id}-curated"
  } else {
    curated_dataset_id
  }
  let version = if version_id == "" {
    "version-\{curated_id}"
  } else {
    version_id
  }
  let transform = if transform_run_id == "" {
    "curate-\{canonical_id}"
  } else {
    transform_run_id
  }
  let lineage = if lineage_id == "" {
    "lineage-\{curated_id}"
  } else {
    lineage_id
  }
  let annotation_id = if annotation_set_id == "" {
    "annotation-\{version}"
  } else {
    annotation_set_id
  }
  let replay_id = if replay_artifact_id == "" {
    "replay-\{version}"
  } else {
    replay_artifact_id
  }
  let export_id = if export_manifest_id == "" {
    "export-\{version}"
  } else {
    export_manifest_id
  }
  let output = if output_uri == "" {
    "moondata://exports/\{export_id}.\{target_format}"
  } else {
    output_uri
  }
  {
    root,
    input_dir,
    dataset_id,
    robot_id,
    bridge_id,
    generated_at_ms,
    canonical_dataset_id: canonical_id,
    quality_run_id: quality_id,
    curated_dataset_id: curated_id,
    version_id: version,
    transform_run_id: transform,
    lineage_id: lineage,
    annotation_set_id: annotation_id,
    replay_artifact_id: replay_id,
    export_manifest_id: export_id,
    target_format,
    output_uri: output,
  }
}

///|
pub fn build_local_file_product(
  request : LocalFileProductRequest,
) -> Result[LocalFileProductResult, @moondata_store.MoonDataStoreIssue] {
  let imported = match
    @moondata_import.import_local_files(
      @moondata_import.local_file_import_request(
        request.root,
        request.input_dir,
        request.dataset_id,
        request.robot_id,
        request.bridge_id,
        "import-\{request.dataset_id}-\{request.generated_at_ms}",
        request.generated_at_ms,
      ),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let normalized = match
    @moondata_normalize.normalize_raw_dataset(
      @moondata_normalize.normalize_request(
        request.root,
        request.dataset_id,
        request.canonical_dataset_id,
        request.generated_at_ms + 1L,
      ),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let quality = match
    @moondata_assess.run_dataset_quality(
      @moondata_assess.dataset_quality_request(
        request.root,
        request.canonical_dataset_id,
        request.generated_at_ms + 2L,
        quality_run_id=request.quality_run_id,
        expected_robot_id=request.robot_id,
        expected_bridge_id=request.bridge_id,
      ),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let curated = match
    @moondata_curate.curate_stored_dataset(
      @moondata_curate.stored_curation_request(
        request.root,
        request.canonical_dataset_id,
        request.quality_run_id,
        request.generated_at_ms + 3L,
        output_dataset_id=request.curated_dataset_id,
        version_id=request.version_id,
        transform_run_id=request.transform_run_id,
        lineage_id=request.lineage_id,
      ),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let review_replay = match write_review_replay(request, curated) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let exported = match
    @moondata_publish.publish_stored_export(
      @moondata_publish.stored_export_request(
        request.root,
        request.version_id,
        request.generated_at_ms + 5L,
        export_manifest_id=request.export_manifest_id,
        target_format=request.target_format,
        output_uri=request.output_uri,
      ),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let validation = match
    @moondata_validate.validate_and_write_root(
      request.root,
      generated_at_ms=request.generated_at_ms + 6L,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let final_catalog = match @moondata_store.read_catalog(request.root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    root: request.root,
    raw_dataset_id: imported.dataset_id,
    canonical_dataset_id: normalized.canonical_dataset_id,
    quality_run_id: quality.quality_run_id,
    curated_dataset_id: curated.curated_dataset_id,
    version_id: curated.version_id,
    annotation_set_id: review_replay.annotation_set_id,
    replay_artifact_id: review_replay.replay_artifact_id,
    export_manifest_id: exported.export_manifest_id,
    validation_report_id: validation.validation_report_id,
    validation_status: validation.status,
    catalog_path: validation.catalog_path,
    catalog_entry_count: final_catalog.entry_count,
    import_result: imported,
    normalize_result: normalized,
    quality_result: quality,
    curation_result: curated,
    annotation_manifest: review_replay.annotation_manifest,
    replay_manifest: review_replay.replay_manifest,
    replay_payload_ref: review_replay.replay_payload_ref,
    export_result: exported,
    validation_result: validation,
  })
}
