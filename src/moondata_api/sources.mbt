///|
pub(all) struct MoonDataSourceQuery {
  source_id_contains : String
  kind : String
  robot_id : String
  bridge_id : String
  origin_contains : String
  label_contains : String
  data_kind : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataSourceList {
  root : String
  query : MoonDataSourceQuery
  source_count : Int
  sources : Array[@moondata_core.DataSource]
  refs : Array[@moondata_core.MoonDataRef]
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn source_query(
  source_id_contains? : String = "",
  kind? : String = "",
  robot_id? : String = "",
  bridge_id? : String = "",
  origin_contains? : String = "",
  label_contains? : String = "",
  data_kind? : String = "",
) -> MoonDataSourceQuery {
  {
    source_id_contains,
    kind,
    robot_id,
    bridge_id,
    origin_contains,
    label_contains,
    data_kind,
  }
}

///|
fn source_query_has_filters(query : MoonDataSourceQuery) -> Bool {
  query.source_id_contains != "" ||
  query.kind != "" ||
  query.robot_id != "" ||
  query.bridge_id != "" ||
  query.origin_contains != "" ||
  query.label_contains != "" ||
  query.data_kind != ""
}

///|
fn source_has_data_kind(
  source : @moondata_core.DataSource,
  data_kind : String,
) -> Bool {
  if data_kind == "" {
    return true
  }
  for source_ref in source.source_refs {
    if source_ref.kind == data_kind {
      return true
    }
  }
  false
}

///|
fn source_matches(
  source : @moondata_core.DataSource,
  query : MoonDataSourceQuery,
) -> Bool {
  if query.source_id_contains != "" &&
    !source.source_id.contains(query.source_id_contains) {
    return false
  }
  if query.kind != "" && source.kind != query.kind {
    return false
  }
  if query.robot_id != "" && source.robot_id != query.robot_id {
    return false
  }
  if query.bridge_id != "" && source.bridge_id != query.bridge_id {
    return false
  }
  if query.origin_contains != "" &&
    !source.origin_uri.contains(query.origin_contains) {
    return false
  }
  if query.label_contains != "" && !source.label.contains(query.label_contains) {
    return false
  }
  source_has_data_kind(source, query.data_kind)
}

///|
fn source_refs(
  root : String,
  sources : Array[@moondata_core.DataSource],
) -> Array[@moondata_core.MoonDataRef] {
  let refs : Array[@moondata_core.MoonDataRef] = []
  for source in sources {
    refs.push(
      @moondata_core.moondata_ref(
        "source",
        source.source_id,
        @moondata_store.source_path(root, source.source_id),
        "\{source.kind} \{source.robot_id}/\{source.bridge_id}",
      ),
    )
  }
  refs
}

///|
pub fn list_sources(
  root : String,
  query? : MoonDataSourceQuery = source_query(),
) -> Result[MoonDataSourceList, @moondata_store.MoonDataStoreIssue] {
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let sources : Array[@moondata_core.DataSource] = []
  for entry in catalog.entries {
    if entry.artifact_kind == "source" {
      let source = match @moondata_store.read_source(root, entry.artifact_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let matches = if source_query_has_filters(query) {
        source_matches(source, query)
      } else {
        true
      }
      if matches {
        sources.push(source)
      }
    }
  }
  let refs = source_refs(root, sources)
  Ok({
    root,
    query,
    source_count: sources.length(),
    sources,
    refs,
    summary: "MoonData sources: \{sources.length()} match(es)",
  })
}
