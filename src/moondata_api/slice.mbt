///|
pub(all) struct MoonDataQualityGateView {
  quality_run_id : @moondata_core.QualityRunId
  status : String
  finding_count : Int
  blocker_count : Int
  warning_count : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataExportView {
  export_manifest_id : @moondata_core.ExportManifestId
  target_format : String
  status : String
  output_refs : Array[@moondata_core.DataRef]
  report : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataDatasetSlice {
  root : String
  version_id : @moondata_core.DatasetVersionId
  dataset_id : @moondata_core.DatasetId
  status : String
  dataset_status : String
  accepted_episode_ids : Array[@moondata_core.EpisodeId]
  accepted_episode_count : Int
  quality_gates : Array[MoonDataQualityGateView]
  exports : Array[MoonDataExportView]
  refs : Array[@moondata_core.MoonDataRef]
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
fn quality_gate_view(
  quality : @moondata_core.QualityRun,
) -> MoonDataQualityGateView {
  {
    quality_run_id: quality.quality_run_id,
    status: quality.status,
    finding_count: quality.finding_count,
    blocker_count: quality.blocker_count,
    warning_count: quality.warning_count,
  }
}

///|
fn export_view(manifest : @moondata_core.ExportManifest) -> MoonDataExportView {
  {
    export_manifest_id: manifest.export_manifest_id,
    target_format: manifest.target_format,
    status: manifest.status,
    output_refs: manifest.output_refs,
    report: manifest.report,
  }
}

///|
fn all_quality_passed(gates : Array[MoonDataQualityGateView]) -> Bool {
  if gates.length() == 0 {
    return false
  }
  for gate in gates {
    if gate.status != "passed" || gate.blocker_count > 0 {
      return false
    }
  }
  true
}

///|
fn slice_status(
  version : @moondata_core.DatasetVersion,
  gates : Array[MoonDataQualityGateView],
  exports : Array[MoonDataExportView],
) -> String {
  if version.status != "accepted" {
    "blocked"
  } else if !all_quality_passed(gates) {
    "blocked"
  } else if exports.length() == 0 {
    "pending-export"
  } else {
    "ready"
  }
}

///|
fn refs_for_slice(
  root : String,
  version : @moondata_core.DatasetVersion,
  gates : Array[MoonDataQualityGateView],
  exports : Array[MoonDataExportView],
) -> Array[@moondata_core.MoonDataRef] {
  let refs : Array[@moondata_core.MoonDataRef] = []
  refs.push(
    @moondata_core.moondata_ref(
      "dataset-version",
      version.version_id,
      @moondata_store.dataset_version_path(root, version.version_id),
      version.summary,
    ),
  )
  refs.push(
    @moondata_core.moondata_ref(
      "dataset",
      version.dataset_id,
      @moondata_store.dataset_kind_path(root, "curated", version.dataset_id),
      "curated dataset for slice \{version.version_id}",
    ),
  )
  for gate in gates {
    refs.push(
      @moondata_core.moondata_ref(
        "quality-run",
        gate.quality_run_id,
        @moondata_store.quality_run_path(root, gate.quality_run_id),
        "quality gate \{gate.status}",
      ),
    )
  }
  for published in exports {
    refs.push(
      @moondata_core.moondata_ref(
        "export-manifest",
        published.export_manifest_id,
        @moondata_store.export_manifest_path(root, published.export_manifest_id),
        published.report,
      ),
    )
  }
  refs
}

///|
fn matching_exports(
  root : String,
  catalog : @moondata_core.MoonDataCatalog,
  version_id : @moondata_core.DatasetVersionId,
) -> Result[Array[MoonDataExportView], @moondata_store.MoonDataStoreIssue] {
  let exports : Array[MoonDataExportView] = []
  for entry in catalog.entries {
    if entry.artifact_kind == "export-manifest" {
      let manifest = match
        @moondata_store.read_export_manifest(root, entry.artifact_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if manifest.input_version_id == version_id {
        exports.push(export_view(manifest))
      }
    }
  }
  Ok(exports)
}

///|
pub fn read_dataset_slice(
  root : String,
  version_id : @moondata_core.DatasetVersionId,
) -> Result[MoonDataDatasetSlice, @moondata_store.MoonDataStoreIssue] {
  let version = match @moondata_store.read_dataset_version(root, version_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let dataset = match
    @moondata_store.read_curated_dataset(root, version.dataset_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let gates : Array[MoonDataQualityGateView] = []
  for quality_run_id in version.quality_run_ids {
    let quality = match @moondata_store.read_quality_run(root, quality_run_id) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    gates.push(quality_gate_view(quality))
  }
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let exports = match matching_exports(root, catalog, version.version_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let status = slice_status(version, gates, exports)
  let refs = refs_for_slice(root, version, gates, exports)
  Ok({
    root,
    version_id: version.version_id,
    dataset_id: version.dataset_id,
    status,
    dataset_status: dataset.status,
    accepted_episode_ids: version.accepted_episode_ids,
    accepted_episode_count: version.accepted_episode_ids.length(),
    quality_gates: gates,
    exports,
    refs,
    summary: "MoonData slice \{status}: version \{version.version_id}, \{version.accepted_episode_ids.length()} accepted episode(s), \{exports.length()} export(s)",
  })
}
