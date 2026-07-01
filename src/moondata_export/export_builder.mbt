///|
pub fn build_export_manifest(
  export_manifest_id : @moondata_core.ExportManifestId,
  version : @moondata_core.DatasetVersion,
  target_format : String,
  field_mapping : String,
  output_refs : Array[@moondata_core.DataRef],
  created_at_ms : Int64,
  status? : String = "ready",
  report? : String = "",
) -> @moondata_core.ExportManifest {
  @moondata_core.export_manifest(
    export_manifest_id,
    version.version_id,
    version.dataset_id,
    target_format,
    field_mapping,
    output_refs,
    created_at_ms,
    quality_run_ids=version.quality_run_ids,
    status~,
    report~,
  )
}

///|
pub fn export_output_uris(
  manifest : @moondata_core.ExportManifest,
) -> Array[String] {
  let uris : Array[String] = []
  for output in manifest.output_refs {
    uris.push(output.uri)
  }
  uris
}
