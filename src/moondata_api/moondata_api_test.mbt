///|
test "status summarizes catalog entries for suite consumers" {
  let catalog = @moondata_core.moondata_catalog("moondata", 60L, [
    @moondata_core.catalog_entry(
      "dataset", "ds-1", "datasets/canonical/ds-1.json",
    ),
    @moondata_core.catalog_entry("quality-run", "qr-1", "quality/qr-1.json"),
    @moondata_core.catalog_entry(
      "transform-run", "tr-1", "transforms/tr-1.json",
    ),
    @moondata_core.catalog_entry(
      "dataset-version", "ver-1", "versions/ver-1.json",
    ),
    @moondata_core.catalog_entry(
      "annotation-set", "ann-1", "annotations/ann-1.json",
    ),
    @moondata_core.catalog_entry(
      "replay-artifact", "replay-1", "replays/replay-1.json",
    ),
    @moondata_core.catalog_entry(
      "export-manifest", "export-1", "exports/export-1.json",
    ),
  ])
  let status = @moondata_api.status_from_catalog("moondata", catalog)
  assert_true(status.ready)
  assert_eq(status.dataset_count, 1)
  assert_eq(status.curation_count, 2)
  assert_eq(status.export_count, 1)
  assert_eq(status.refs.length(), 7)
}

///|
test "context carries bounded refs and compact summary" {
  let catalog = @moondata_core.moondata_catalog("moondata", 61L, [
    @moondata_core.catalog_entry(
      "export-manifest", "export-1", "exports/export-1.json",
    ),
  ])
  let context = @moondata_api.context_from_status(
    @moondata_api.status_from_catalog("moondata", catalog),
  )
  assert_eq(context.status, "ready")
  assert_true(context.summary.contains("1 cataloged artifact"))
  assert_eq(context.refs[0].artifact_kind, "export-manifest")
}
