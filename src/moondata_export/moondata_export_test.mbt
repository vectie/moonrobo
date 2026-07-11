///|
test "export manifest inherits version quality gate" {
  let version = @moondata_core.dataset_version(
    "version-1",
    "dataset-curated",
    "accepted",
    40L,
    quality_run_ids=["quality-1"],
  )
  let output = @moondata_core.data_ref(
    "export-output", "jsonl", "moondata://exports/export-1.jsonl",
  )
  let manifest = @moondata_export.build_export_manifest(
    "export-1",
    version,
    "jsonl",
    "{\"payload\":\"frame.payload\"}",
    [output],
    41L,
  )
  assert_eq(manifest.input_version_id, "version-1")
  assert_eq(manifest.quality_run_ids[0], "quality-1")
  assert_eq(@moondata_export.export_output_uris(manifest)[0], output.uri)
}
