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
  assert_eq(result.export_result.manifest.status, "ready")
  assert_true(result.export_result.output_byte_count > 0L)
  assert_eq(
    result.export_result.manifest.quality_run_ids[0],
    "qr-ds-pipeline-canonical",
  )
  assert_true(result.catalog_entry_count >= 14)
}
