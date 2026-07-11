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
  source_ref_count : Int
  total_source_byte_count : Int64
  source_checksums : Array[String]
  latest_source_id : String
  latest_source_created_at_ms : Int64
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
priv struct SourceListSummary {
  source_ref_count : Int
  total_source_byte_count : Int64
  source_checksums : Array[String]
  latest_source_id : String
  latest_source_created_at_ms : Int64
}

///|
fn source_list_summary(
  sources : Array[@moondata_core.DataSource],
) -> SourceListSummary {
  let mut source_ref_count = 0
  let mut total_source_byte_count = 0L
  let source_checksums : Array[String] = []
  let mut latest_id = ""
  let mut latest_created_at_ms = -1L
  for source in sources {
    source_ref_count += source.source_refs.length()
    for source_ref in source.source_refs {
      total_source_byte_count += source_ref.byte_count
      push_unique_checksum(source_checksums, source_ref.checksum)
    }
    if source.created_at_ms > latest_created_at_ms {
      latest_id = source.source_id
      latest_created_at_ms = source.created_at_ms
    }
  }
  if latest_id == "" {
    return {
      source_ref_count,
      total_source_byte_count,
      source_checksums,
      latest_source_id: "",
      latest_source_created_at_ms: 0L,
    }
  }
  {
    source_ref_count,
    total_source_byte_count,
    source_checksums,
    latest_source_id: latest_id,
    latest_source_created_at_ms: latest_created_at_ms,
  }
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
  let evidence = source_list_summary(sources)
  Ok({
    root,
    query,
    source_count: sources.length(),
    source_ref_count: evidence.source_ref_count,
    total_source_byte_count: evidence.total_source_byte_count,
    source_checksums: evidence.source_checksums,
    latest_source_id: evidence.latest_source_id,
    latest_source_created_at_ms: evidence.latest_source_created_at_ms,
    sources,
    refs,
    summary: "MoonData sources: \{sources.length()} match(es), \{evidence.source_ref_count} source ref(s), \{evidence.total_source_byte_count} byte(s), latest \{evidence.latest_source_id}",
  })
}
