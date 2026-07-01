///|
fn ensure_dir(path : String) -> Unit raise {
  if !@fsx.path_exists(path) {
    @fsx.create_dir(path) catch {
      _ => fail("failed to create " + path)
    }
  }
}

///|
fn write_input(input : String) -> Unit raise {
  ensure_dir("target")
  ensure_dir(input)
  @fsx.write_string_to_file(input + "/frame-a.json", "{\"t\":1}") catch {
    _ => fail("write input a failed")
  }
  @fsx.write_string_to_file(input + "/frame-b.csv", "t,x\n2,4\n") catch {
    _ => fail("write input b failed")
  }
}

///|
test "build local file product reaches quality gated export" {
  let root = "target/moondata-pipeline-test"
  let input = "target/moondata-pipeline-input"
  write_input(input)
  let result = match
    @moondata_pipeline.build_local_file_product(
      @moondata_pipeline.local_file_product_request(
        root, input, "ds-pipeline", "robot-pipeline", "bridge-pipeline", 900L,
      ),
    ) {
    Ok(value) => value
    Err(error) => fail("pipeline failed: " + error.message)
  }
  assert_eq(result.raw_dataset_id, "ds-pipeline")
  assert_eq(result.import_result.episode.status, "stopped")
  assert_eq(result.quality_result.quality.status, "passed")
  assert_eq(result.curation_result.version.status, "accepted")
  assert_eq(
    result.annotation_set_id,
    "annotation-version-ds-pipeline-canonical-curated",
  )
  assert_eq(
    result.annotation_index_id,
    "annotation-target-annotation-version-ds-pipeline-canonical-curated",
  )
  assert_eq(
    result.replay_artifact_id,
    "replay-version-ds-pipeline-canonical-curated",
  )
  assert_eq(result.annotation_manifest.artifact_kind, "annotation-set")
  assert_eq(
    result.annotation_index_manifest.artifact_kind,
    "annotation-target-index",
  )
  assert_eq(result.replay_manifest.artifact_kind, "replay-artifact")
  assert_eq(result.replay_payload_ref.kind, "replay-payload")
  assert_true(
    result.replay_payload_ref.uri.contains(
      "moondata://media/replays/replay-version-ds-pipeline-canonical-curated.json",
    ),
  )
  assert_eq(result.export_result.manifest.status, "ready")
  assert_eq(result.validation_status, "passed")
  assert_true(result.ready)
  assert_eq(result.validation_result.report.status, "passed")
  assert_eq(result.validation_report_id, "validation-907")
  assert_true(result.export_result.output_byte_count > 0L)
  assert_eq(result.export_result.output_record_count, 2)
  assert_eq(
    result.export_result.output_checksum,
    result.export_result.manifest.output_refs[0].checksum,
  )
  assert_eq(
    result.export_result.manifest.quality_run_ids[0],
    "qr-ds-pipeline-canonical",
  )
  assert_true(result.catalog_entry_count >= 19)
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(_) => fail("read final catalog failed")
  }
  let target_index = match
    @moondata_store.read_annotation_target_index(
      root,
      result.annotation_index_id,
    ) {
    Ok(value) => value
    Err(_) => fail("read annotation target index failed")
  }
  assert_eq(target_index.annotation_set_id, result.annotation_set_id)
  assert_true(target_index.target_refs.length() >= 4)
  assert_eq(
    catalog.entries[catalog.entries.length() - 1].artifact_kind,
    "validation-report",
  )
}
