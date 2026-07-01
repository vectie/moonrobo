///|
pub(all) struct MoonDataStatus {
  root : String
  catalog_path : String
  generated_at_ms : Int64
  ready : Bool
  entry_count : Int
  dataset_count : Int
  quality_count : Int
  curation_count : Int
  annotation_count : Int
  replay_count : Int
  export_count : Int
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
pub fn status_from_catalog(
  root : String,
  catalog : @moondata_core.MoonDataCatalog,
) -> MoonDataStatus {
  let dataset_count = count_kind(catalog, "dataset")
  let quality_count = count_kind(catalog, "quality-run")
  let transform_count = count_kind(catalog, "transform-run")
  let version_count = count_kind(catalog, "dataset-version")
  let annotation_count = count_kind(catalog, "annotation-set")
  let replay_count = count_kind(catalog, "replay-artifact")
  let export_count = count_kind(catalog, "export-manifest")
  {
    root,
    catalog_path: @moondata_store.catalog_path(root),
    generated_at_ms: catalog.generated_at_ms,
    ready: catalog.entry_count > 0,
    entry_count: catalog.entry_count,
    dataset_count,
    quality_count,
    curation_count: transform_count + version_count,
    annotation_count,
    replay_count,
    export_count,
    refs: @moondata_core.catalog_refs(catalog),
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
  Ok(status_from_catalog(root, catalog))
}
