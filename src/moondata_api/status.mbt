///|
pub(all) struct MoonDataStatus {
  root : String
  catalog_path : String
  generated_at_ms : Int64
  ready : Bool
  entry_count : Int
  source_count : Int
  capture_count : Int
  dataset_count : Int
  episode_count : Int
  frame_count : Int
  signal_count : Int
  quality_count : Int
  transform_count : Int
  version_count : Int
  curation_count : Int
  annotation_count : Int
  annotation_index_count : Int
  replay_count : Int
  export_count : Int
  lineage_count : Int
  validation_count : Int
  handoff_count : Int
  latest_validation_report_id : String
  latest_validation_status : String
  latest_validation_generated_at_ms : Int64
  latest_validation_catalog_entry_count : Int
  latest_validation_covers_catalog : Bool
  latest_validation_finding_count : Int
  latest_validation_blocker_count : Int
  latest_validation_warning_count : Int
  refs : Array[@moondata_core.MoonDataRef]
} derive(Debug, Eq, ToJson, FromJson)

///|
fn count_kind(catalog : @moondata_core.MoonDataCatalog, kind : String) -> Int {
  let mut count = 0
  for entry in catalog.entries {
    if entry.artifact_kind == kind {
      count += 1
    }
  }
  count
}

///|
fn latest_validation_entry(
  catalog : @moondata_core.MoonDataCatalog,
) -> @moondata_core.CatalogEntry? {
  let mut latest : @moondata_core.CatalogEntry? = None
  for entry in catalog.entries {
    if entry.artifact_kind == "validation-report" {
      latest = Some(entry)
    }
  }
  latest
}

///|
fn status_from_catalog_status(
  root : String,
  catalog : @moondata_core.MoonDataCatalog,
  latest_validation_report_id : String,
  latest_validation_status : String,
  latest_validation_generated_at_ms : Int64,
  latest_validation_catalog_entry_count : Int,
  latest_validation_covers_catalog : Bool,
  latest_validation_finding_count : Int,
  latest_validation_blocker_count : Int,
  latest_validation_warning_count : Int,
) -> MoonDataStatus {
  let source_count = count_kind(catalog, "source")
  let capture_count = count_kind(catalog, "capture")
  let dataset_count = count_kind(catalog, "dataset")
  let episode_count = count_kind(catalog, "episode")
  let frame_count = count_kind(catalog, "frame")
  let signal_count = count_kind(catalog, "signal-series")
  let quality_count = count_kind(catalog, "quality-run")
  let transform_count = count_kind(catalog, "transform-run")
  let version_count = count_kind(catalog, "dataset-version")
  let annotation_count = count_kind(catalog, "annotation-set")
  let annotation_index_count = count_kind(catalog, "annotation-target-index")
  let replay_count = count_kind(catalog, "replay-artifact")
  let export_count = count_kind(catalog, "export-manifest")
  let lineage_count = count_kind(catalog, "lineage")
  let validation_count = count_kind(catalog, "validation-report")
  let handoff_count = count_kind(catalog, "handoff-dossier")
  {
    root,
    catalog_path: @moondata_store.catalog_path(root),
    generated_at_ms: catalog.generated_at_ms,
    ready: catalog.entry_count > 0 && latest_validation_status == "passed",
    entry_count: catalog.entry_count,
    source_count,
    capture_count,
    dataset_count,
    episode_count,
    frame_count,
    signal_count,
    quality_count,
    transform_count,
    version_count,
    curation_count: transform_count + version_count,
    annotation_count,
    annotation_index_count,
    replay_count,
    export_count,
    lineage_count,
    validation_count,
    handoff_count,
    latest_validation_report_id,
    latest_validation_status,
    latest_validation_generated_at_ms,
    latest_validation_catalog_entry_count,
    latest_validation_covers_catalog,
    latest_validation_finding_count,
    latest_validation_blocker_count,
    latest_validation_warning_count,
    refs: @moondata_core.catalog_refs(catalog),
  }
}

///|
pub fn status_from_catalog(
  root : String,
  catalog : @moondata_core.MoonDataCatalog,
) -> MoonDataStatus {
  let latest_validation = latest_validation_entry(catalog)
  let latest_validation_report_id = match latest_validation {
    Some(entry) => entry.artifact_id
    None => ""
  }
  let latest_validation_status = match latest_validation {
    Some(_) => "catalog-only"
    None => "unvalidated"
  }
  status_from_catalog_status(
    root, catalog, latest_validation_report_id, latest_validation_status, 0L, 0,
    false, 0, 0, 0,
  )
}

///|
priv struct LatestValidationSummary {
  validation_report_id : String
  status : String
  generated_at_ms : Int64
  catalog_entry_count : Int
  covers_catalog : Bool
  finding_count : Int
  blocker_count : Int
  warning_count : Int
}

///|
fn catalog_has_validation_report(
  catalog : @moondata_core.MoonDataCatalog,
  validation_report_id : String,
) -> Bool {
  for entry in catalog.entries {
    if entry.artifact_kind == "validation-report" &&
      entry.artifact_id == validation_report_id {
      return true
    }
  }
  false
}

///|
fn validation_covers_catalog(
  catalog : @moondata_core.MoonDataCatalog,
  validation_report_id : String,
  validation_generated_at_ms : Int64,
  validation_catalog_entry_count : Int,
) -> Bool {
  if validation_generated_at_ms < catalog.generated_at_ms {
    return false
  }
  validation_catalog_entry_count == catalog.entry_count ||
  (
    validation_catalog_entry_count + 1 == catalog.entry_count &&
    catalog_has_validation_report(catalog, validation_report_id)
  )
}

///|
fn latest_validation_summary_from_store(
  root : String,
  catalog : @moondata_core.MoonDataCatalog,
) -> LatestValidationSummary {
  let mut latest_id = ""
  let mut latest_status = ""
  let mut latest_catalog_entry_count = 0
  let mut latest_finding_count = 0
  let mut latest_blocker_count = 0
  let mut latest_warning_count = 0
  let mut latest_generated_at_ms = -1L
  let mut missing_id = ""
  for entry in catalog.entries {
    if entry.artifact_kind == "validation-report" {
      match @moondata_store.read_validation_report(root, entry.artifact_id) {
        Ok(report) =>
          if report.generated_at_ms > latest_generated_at_ms {
            latest_id = report.validation_report_id
            latest_status = report.status
            latest_catalog_entry_count = report.catalog_entry_count
            latest_finding_count = report.finding_count
            latest_blocker_count = report.blocker_count
            latest_warning_count = report.warning_count
            latest_generated_at_ms = report.generated_at_ms
          }
        Err(_) => if missing_id == "" { missing_id = entry.artifact_id }
      }
    }
  }
  if latest_id == "" {
    if missing_id == "" {
      {
        validation_report_id: "",
        status: "unvalidated",
        generated_at_ms: 0L,
        catalog_entry_count: 0,
        covers_catalog: false,
        finding_count: 0,
        blocker_count: 0,
        warning_count: 0,
      }
    } else {
      {
        validation_report_id: missing_id,
        status: "missing",
        generated_at_ms: 0L,
        catalog_entry_count: 0,
        covers_catalog: false,
        finding_count: 0,
        blocker_count: 0,
        warning_count: 0,
      }
    }
  } else {
    let covers_catalog = validation_covers_catalog(
      catalog, latest_id, latest_generated_at_ms, latest_catalog_entry_count,
    )
    if !covers_catalog {
      {
        validation_report_id: latest_id,
        status: "stale",
        generated_at_ms: latest_generated_at_ms,
        catalog_entry_count: latest_catalog_entry_count,
        covers_catalog,
        finding_count: latest_finding_count,
        blocker_count: latest_blocker_count,
        warning_count: latest_warning_count,
      }
    } else {
      {
        validation_report_id: latest_id,
        status: latest_status,
        generated_at_ms: latest_generated_at_ms,
        catalog_entry_count: latest_catalog_entry_count,
        covers_catalog,
        finding_count: latest_finding_count,
        blocker_count: latest_blocker_count,
        warning_count: latest_warning_count,
      }
    }
  }
}

///|
pub fn read_status(
  root : String,
) -> Result[MoonDataStatus, @moondata_store.MoonDataStoreIssue] {
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let latest_validation = latest_validation_summary_from_store(root, catalog)
  Ok(
    status_from_catalog_status(
      root,
      catalog,
      latest_validation.validation_report_id,
      latest_validation.status,
      latest_validation.generated_at_ms,
      latest_validation.catalog_entry_count,
      latest_validation.covers_catalog,
      latest_validation.finding_count,
      latest_validation.blocker_count,
      latest_validation.warning_count,
    ),
  )
}
