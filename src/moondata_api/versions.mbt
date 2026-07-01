///|
pub(all) struct MoonDataVersionQuery {
  dataset_id : String
  status : String
  parent_version_id : String
  episode_id : String
  quality_run_id : String
  summary_contains : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataVersionList {
  root : String
  query : MoonDataVersionQuery
  version_count : Int
  versions : Array[@moondata_core.DatasetVersion]
  refs : Array[@moondata_core.MoonDataRef]
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn version_query(
  dataset_id? : String = "",
  status? : String = "",
  parent_version_id? : String = "",
  episode_id? : String = "",
  quality_run_id? : String = "",
  summary_contains? : String = "",
) -> MoonDataVersionQuery {
  {
    dataset_id,
    status,
    parent_version_id,
    episode_id,
    quality_run_id,
    summary_contains,
  }
}

///|
fn version_query_has_filters(query : MoonDataVersionQuery) -> Bool {
  query.dataset_id != "" ||
  query.status != "" ||
  query.parent_version_id != "" ||
  query.episode_id != "" ||
  query.quality_run_id != "" ||
  query.summary_contains != ""
}

///|
fn version_matches(
  version : @moondata_core.DatasetVersion,
  query : MoonDataVersionQuery,
) -> Bool {
  if query.dataset_id != "" && version.dataset_id != query.dataset_id {
    return false
  }
  if query.status != "" && version.status != query.status {
    return false
  }
  if query.parent_version_id != "" &&
    !contains_id(version.parent_version_ids, query.parent_version_id) {
    return false
  }
  if query.episode_id != "" &&
    !contains_id(version.accepted_episode_ids, query.episode_id) {
    return false
  }
  if query.quality_run_id != "" &&
    !contains_id(version.quality_run_ids, query.quality_run_id) {
    return false
  }
  query.summary_contains == "" ||
  version.summary.contains(query.summary_contains)
}

///|
fn version_refs(
  root : String,
  versions : Array[@moondata_core.DatasetVersion],
) -> Array[@moondata_core.MoonDataRef] {
  let refs : Array[@moondata_core.MoonDataRef] = []
  for version in versions {
    refs.push(
      @moondata_core.moondata_ref(
        "dataset-version",
        version.version_id,
        @moondata_store.dataset_version_path(root, version.version_id),
        version.summary,
      ),
    )
  }
  refs
}

///|
pub fn list_versions(
  root : String,
  query? : MoonDataVersionQuery = version_query(),
) -> Result[MoonDataVersionList, @moondata_store.MoonDataStoreIssue] {
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let versions : Array[@moondata_core.DatasetVersion] = []
  for entry in catalog.entries {
    if entry.artifact_kind == "dataset-version" {
      let version = match
        @moondata_store.read_dataset_version(root, entry.artifact_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let matches = if version_query_has_filters(query) {
        version_matches(version, query)
      } else {
        true
      }
      if matches {
        versions.push(version)
      }
    }
  }
  let refs = version_refs(root, versions)
  Ok({
    root,
    query,
    version_count: versions.length(),
    versions,
    refs,
    summary: "MoonData versions: \{versions.length()} match(es)",
  })
}
