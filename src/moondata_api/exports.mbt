///|
pub(all) struct MoonDataExportQuery {
  version_id : String
  dataset_id : String
  target_format : String
  status : String
  quality_run_id : String
  output_kind : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataExportList {
  root : String
  query : MoonDataExportQuery
  export_count : Int
  output_ref_count : Int
  total_output_byte_count : Int64
  output_checksums : Array[String]
  exports : Array[@moondata_core.ExportManifest]
  refs : Array[@moondata_core.MoonDataRef]
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn export_query(
  version_id? : String = "",
  dataset_id? : String = "",
  target_format? : String = "",
  status? : String = "",
  quality_run_id? : String = "",
  output_kind? : String = "",
) -> MoonDataExportQuery {
  { version_id, dataset_id, target_format, status, quality_run_id, output_kind }
}

///|
fn export_query_has_filters(query : MoonDataExportQuery) -> Bool {
  query.version_id != "" ||
  query.dataset_id != "" ||
  query.target_format != "" ||
  query.status != "" ||
  query.quality_run_id != "" ||
  query.output_kind != ""
}

///|
fn output_refs_match_kind(
  refs : Array[@moondata_core.DataRef],
  output_kind : String,
) -> Bool {
  if output_kind == "" {
    return true
  }
  for output_ref in refs {
    if output_ref.kind == output_kind {
      return true
    }
  }
  false
}

///|
fn export_matches(
  manifest : @moondata_core.ExportManifest,
  query : MoonDataExportQuery,
) -> Bool {
  if query.version_id != "" && manifest.input_version_id != query.version_id {
    return false
  }
  if query.dataset_id != "" && manifest.dataset_id != query.dataset_id {
    return false
  }
  if query.target_format != "" && manifest.target_format != query.target_format {
    return false
  }
  if query.status != "" && manifest.status != query.status {
    return false
  }
  if query.quality_run_id != "" &&
    !contains_id(manifest.quality_run_ids, query.quality_run_id) {
    return false
  }
  output_refs_match_kind(manifest.output_refs, query.output_kind)
}

///|
fn export_refs(
  root : String,
  manifests : Array[@moondata_core.ExportManifest],
) -> Array[@moondata_core.MoonDataRef] {
  let refs : Array[@moondata_core.MoonDataRef] = []
  for manifest in manifests {
    refs.push(
      @moondata_core.moondata_ref(
        "export-manifest",
        manifest.export_manifest_id,
        @moondata_store.export_manifest_path(root, manifest.export_manifest_id),
        manifest.report,
      ),
    )
  }
  refs
}

///|
fn push_unique_checksum(checksums : Array[String], checksum : String) -> Unit {
  if checksum == "" {
    return
  }
  for existing in checksums {
    if existing == checksum {
      return
    }
  }
  checksums.push(checksum)
}

///|
fn output_ref_count(manifests : Array[@moondata_core.ExportManifest]) -> Int {
  let mut count = 0
  for manifest in manifests {
    count += manifest.output_refs.length()
  }
  count
}

///|
fn total_output_byte_count(
  manifests : Array[@moondata_core.ExportManifest],
) -> Int64 {
  let mut count = 0L
  for manifest in manifests {
    for output in manifest.output_refs {
      count += output.byte_count
    }
  }
  count
}

///|
fn output_checksums(
  manifests : Array[@moondata_core.ExportManifest],
) -> Array[String] {
  let checksums : Array[String] = []
  for manifest in manifests {
    for output in manifest.output_refs {
      push_unique_checksum(checksums, output.checksum)
    }
  }
  checksums
}

///|
pub fn list_exports(
  root : String,
  query? : MoonDataExportQuery = export_query(),
) -> Result[MoonDataExportList, @moondata_store.MoonDataStoreIssue] {
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let exports : Array[@moondata_core.ExportManifest] = []
  for entry in catalog.entries {
    if entry.artifact_kind == "export-manifest" {
      let manifest = match
        @moondata_store.read_export_manifest(root, entry.artifact_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let matches = if export_query_has_filters(query) {
        export_matches(manifest, query)
      } else {
        true
      }
      if matches {
        exports.push(manifest)
      }
    }
  }
  let refs = export_refs(root, exports)
  let output_count = output_ref_count(exports)
  let byte_count = total_output_byte_count(exports)
  let checksums = output_checksums(exports)
  Ok({
    root,
    query,
    export_count: exports.length(),
    output_ref_count: output_count,
    total_output_byte_count: byte_count,
    output_checksums: checksums,
    exports,
    refs,
    summary: "MoonData exports: \{exports.length()} match(es), \{output_count} output ref(s), \{byte_count} byte(s)",
  })
}
