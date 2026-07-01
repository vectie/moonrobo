///|
test "catalog validation passes complete local catalog" {
  let root = "target/moondata-validate-test"
  ignore(@moondata_store.initialize_root(root))
  let dataset = @moondata_core.dataset_manifest(
    "dataset-validate", "canonical", "active", 1L,
  )
  let persisted = match @moondata_store.write_dataset(root, dataset) {
    Ok(value) => value
    Err(_) => fail("write dataset failed")
  }
  let catalog = @moondata_core.moondata_catalog(root, 2L, [
    @moondata_core.catalog_entry(
      persisted.artifact_kind,
      persisted.artifact_id,
      persisted.path,
      status="active",
    ),
  ])
  ignore(@moondata_store.write_catalog(root, catalog))
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=3L) {
    Ok(value) => value
    Err(_) => fail("validate root failed")
  }
  assert_eq(report.status, "passed")
  assert_eq(report.finding_count, 0)
  assert_eq(report.catalog_entry_count, 1)
}

///|
test "catalog validation blocks duplicate and missing manifests" {
  let catalog = @moondata_core.moondata_catalog("moondata", 4L, [
    @moondata_core.catalog_entry("dataset", "dataset-a", "moondata://missing"),
    @moondata_core.catalog_entry(
      "dataset", "dataset-a", "moondata://missing-again",
    ),
  ])
  let report = @moondata_validate.validate_catalog(
    "moondata",
    catalog,
    generated_at_ms=5L,
    check_files=true,
  )
  assert_eq(report.status, "blocked")
  assert_true(report.blocker_count > 0)
  assert_true(report.warning_count > 0)
}
