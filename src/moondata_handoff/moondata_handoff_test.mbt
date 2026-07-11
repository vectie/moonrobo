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
fn remove_file_if_exists(path : String) -> Unit raise {
  if @fsx.path_exists(path) {
    @fsx.remove_file(path) catch {
      _ => fail("failed to remove stale test file: " + path)
    }
  }
}

///|
test "materialize stored handoff writes validated dossier artifact" {
  let root = "target/moondata-handoff-output-refs-test"
  let input = "target/moondata-handoff-output-refs-input"
  remove_file_if_exists(
    @moondata_store.handoff_dossier_path(root, "handoff-version-ds-handoff"),
  )
  remove_file_if_exists(
    @moondata_store.validation_report_path(root, "validation-3100"),
  )
  remove_file_if_exists(
    @moondata_store.validation_report_path(root, "validation-3101"),
  )
  write_input(input)
  let product = match
    @moondata_pipeline.build_local_file_product(
      @moondata_pipeline.local_file_product_request(
        root, input, "ds-handoff", "robot-handoff", "bridge-handoff", 3000L,
      ),
    ) {
    Ok(value) => value
    Err(error) => fail("pipeline failed: " + error.message)
  }
  assert_true(product.ready)
  let result = match
    @moondata_handoff.materialize_stored_handoff(
      @moondata_handoff.stored_handoff_request(
        root,
        3100L,
        version_id=product.version_id,
        handoff_dossier_id="handoff-version-ds-handoff",
      ),
    ) {
    Ok(value) => value
    Err(error) => fail("handoff failed: " + error.message)
  }
  assert_eq(result.handoff_dossier_id, "handoff-version-ds-handoff")
  assert_eq(result.version_id, product.version_id)
  assert_eq(result.source_readiness_status, "ready")
  assert_eq(result.source_repair_work_count, 0)
  assert_eq(result.source_repair_open_count, 0)
  assert_eq(result.source_repair_applied_unvalidated_count, 0)
  assert_true(result.dossier.source_validation_report_id != "")
  assert_eq(result.dossier.source_validation_status, "passed")
  assert_eq(result.dossier.source_repair_work_count, 0)
  assert_eq(result.dossier.source_repair_open_count, 0)
  assert_eq(result.dossier.source_repair_applied_unvalidated_count, 0)
  assert_eq(result.dossier.output_ref_count, 1)
  assert_true(result.dossier.total_output_byte_count > 0L)
  assert_true(result.dossier.ref_count > 0)
  assert_eq(result.dossier_manifest.artifact_kind, "handoff-dossier")
  assert_eq(result.validation_result.status, "passed")
  assert_true(result.ready)
  let stored = match
    @moondata_store.read_handoff_dossier(root, result.handoff_dossier_id) {
    Ok(value) => value
    Err(_) => fail("read stored handoff dossier failed")
  }
  assert_eq(stored.handoff_dossier_id, result.handoff_dossier_id)
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(_) => fail("read handoff catalog failed")
  }
  assert_eq(
    catalog.entries[catalog.entries.length() - 2].artifact_kind,
    "handoff-dossier",
  )
  assert_eq(
    catalog.entries[catalog.entries.length() - 1].artifact_kind,
    "validation-report",
  )
}
