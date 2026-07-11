///|
pub(all) struct MoonDataArtifactQuery {
  artifact_kind : String
  status : String
  artifact_id_contains : String
  summary_contains : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataArtifactList {
  root : String
  query : MoonDataArtifactQuery
  artifact_count : Int
  artifacts : Array[@moondata_core.CatalogEntry]
  refs : Array[@moondata_core.MoonDataRef]
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn artifact_query(
  artifact_kind? : String = "",
  status? : String = "",
  artifact_id_contains? : String = "",
  summary_contains? : String = "",
) -> MoonDataArtifactQuery {
  { artifact_kind, status, artifact_id_contains, summary_contains }
}

///|
fn artifact_query_has_filters(query : MoonDataArtifactQuery) -> Bool {
  query.artifact_kind != "" ||
  query.status != "" ||
  query.artifact_id_contains != "" ||
  query.summary_contains != ""
}

///|
fn artifact_matches(
  entry : @moondata_core.CatalogEntry,
  query : MoonDataArtifactQuery,
) -> Bool {
  if query.artifact_kind != "" && entry.artifact_kind != query.artifact_kind {
    return false
  }
  if query.status != "" && entry.status != query.status {
    return false
  }
  if query.artifact_id_contains != "" &&
    !entry.artifact_id.contains(query.artifact_id_contains) {
    return false
  }
  if query.summary_contains != "" &&
    !entry.summary.contains(query.summary_contains) {
    return false
  }
  true
}

///|
fn artifact_refs(
  entries : Array[@moondata_core.CatalogEntry],
) -> Array[@moondata_core.MoonDataRef] {
  let refs : Array[@moondata_core.MoonDataRef] = []
  for entry in entries {
    refs.push(@moondata_core.entry_ref(entry))
  }
  refs
}

///|
pub fn list_artifacts(
  root : String,
  query? : MoonDataArtifactQuery = artifact_query(),
) -> Result[MoonDataArtifactList, @moondata_store.MoonDataStoreIssue] {
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let artifacts : Array[@moondata_core.CatalogEntry] = []
  for entry in catalog.entries {
    let matches = if artifact_query_has_filters(query) {
      artifact_matches(entry, query)
    } else {
      true
    }
    if matches {
      artifacts.push(entry)
    }
  }
  let refs = artifact_refs(artifacts)
  Ok({
    root,
    query,
    artifact_count: artifacts.length(),
    artifacts,
    refs,
    summary: "MoonData artifacts: \{artifacts.length()} match(es)",
  })
}
