///|
pub(all) struct MoonDataLineageQuery {
  lineage_id : String
  root_dataset_id : String
  node_id : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataLineageNode {
  artifact_id : String
  artifact_kind : String
  status : String
  manifest_path : String
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataLineageGraph {
  root : String
  query : MoonDataLineageQuery
  lineage_count : Int
  node_count : Int
  edge_count : Int
  lineages : Array[@moondata_core.LineageManifest]
  nodes : Array[MoonDataLineageNode]
  edges : Array[@moondata_core.LineageEdge]
  refs : Array[@moondata_core.MoonDataRef]
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn lineage_query(
  lineage_id? : String = "",
  root_dataset_id? : String = "",
  node_id? : String = "",
) -> MoonDataLineageQuery {
  { lineage_id, root_dataset_id, node_id }
}

///|
fn lineage_query_has_filters(query : MoonDataLineageQuery) -> Bool {
  query.lineage_id != "" || query.root_dataset_id != "" || query.node_id != ""
}

///|
fn lineage_contains_node(
  lineage : @moondata_core.LineageManifest,
  node_id : String,
) -> Bool {
  if node_id == "" {
    return true
  }
  if lineage.root_dataset_id == node_id {
    return true
  }
  for edge in lineage.edges {
    if edge.from_id == node_id || edge.to_id == node_id {
      return true
    }
  }
  false
}

///|
fn lineage_matches(
  lineage : @moondata_core.LineageManifest,
  query : MoonDataLineageQuery,
) -> Bool {
  if query.lineage_id != "" && lineage.lineage_id != query.lineage_id {
    return false
  }
  if query.root_dataset_id != "" &&
    lineage.root_dataset_id != query.root_dataset_id {
    return false
  }
  lineage_contains_node(lineage, query.node_id)
}

///|
fn push_unique_id(ids : Array[String], id : String) -> Unit {
  for seen in ids {
    if seen == id {
      return
    }
  }
  ids.push(id)
}

///|
fn lineage_node_ids(
  lineages : Array[@moondata_core.LineageManifest],
) -> Array[String] {
  let ids : Array[String] = []
  for lineage in lineages {
    push_unique_id(ids, lineage.root_dataset_id)
    push_unique_id(ids, lineage.lineage_id)
    for edge in lineage.edges {
      push_unique_id(ids, edge.from_id)
      push_unique_id(ids, edge.to_id)
    }
  }
  ids
}

///|
fn catalog_entry_for_id(
  entries : Array[@moondata_core.CatalogEntry],
  artifact_id : String,
) -> @moondata_core.CatalogEntry? {
  for entry in entries {
    if entry.artifact_id == artifact_id {
      return Some(entry)
    }
  }
  None
}

///|
fn lineage_node_from_entry(
  entry : @moondata_core.CatalogEntry,
) -> MoonDataLineageNode {
  {
    artifact_id: entry.artifact_id,
    artifact_kind: entry.artifact_kind,
    status: entry.status,
    manifest_path: entry.manifest_path,
    summary: entry.summary,
  }
}

///|
fn uncataloged_lineage_node(artifact_id : String) -> MoonDataLineageNode {
  {
    artifact_id,
    artifact_kind: "uncataloged",
    status: "",
    manifest_path: "",
    summary: "",
  }
}

///|
fn lineage_nodes(
  catalog : @moondata_core.MoonDataCatalog,
  lineages : Array[@moondata_core.LineageManifest],
) -> Array[MoonDataLineageNode] {
  let nodes : Array[MoonDataLineageNode] = []
  for id in lineage_node_ids(lineages) {
    match catalog_entry_for_id(catalog.entries, id) {
      Some(entry) => nodes.push(lineage_node_from_entry(entry))
      None => nodes.push(uncataloged_lineage_node(id))
    }
  }
  nodes
}

///|
fn lineage_edges(
  lineages : Array[@moondata_core.LineageManifest],
) -> Array[@moondata_core.LineageEdge] {
  let edges : Array[@moondata_core.LineageEdge] = []
  for lineage in lineages {
    for edge in lineage.edges {
      edges.push(edge)
    }
  }
  edges
}

///|
fn lineage_refs(
  nodes : Array[MoonDataLineageNode],
) -> Array[@moondata_core.MoonDataRef] {
  let refs : Array[@moondata_core.MoonDataRef] = []
  for node in nodes {
    if node.artifact_kind != "uncataloged" {
      refs.push(
        @moondata_core.moondata_ref(
          node.artifact_kind,
          node.artifact_id,
          node.manifest_path,
          node.summary,
        ),
      )
    }
  }
  refs
}

///|
pub fn read_lineage_graph(
  root : String,
  query? : MoonDataLineageQuery = lineage_query(),
) -> Result[MoonDataLineageGraph, @moondata_store.MoonDataStoreIssue] {
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let lineages : Array[@moondata_core.LineageManifest] = []
  for entry in catalog.entries {
    if entry.artifact_kind == "lineage" {
      let lineage = match
        @moondata_store.read_lineage_manifest(root, entry.artifact_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let matches = if lineage_query_has_filters(query) {
        lineage_matches(lineage, query)
      } else {
        true
      }
      if matches {
        lineages.push(lineage)
      }
    }
  }
  let nodes = lineage_nodes(catalog, lineages)
  let edges = lineage_edges(lineages)
  let refs = lineage_refs(nodes)
  Ok({
    root,
    query,
    lineage_count: lineages.length(),
    node_count: nodes.length(),
    edge_count: edges.length(),
    lineages,
    nodes,
    edges,
    refs,
    summary: "MoonData lineage: \{lineages.length()} lineage(s), \{edges.length()} edge(s)",
  })
}
