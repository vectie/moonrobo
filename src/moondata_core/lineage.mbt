///|
pub(all) struct LineageEdge {
  from_id : String
  to_id : String
  relation : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct LineageManifest {
  lineage_id : String
  root_dataset_id : DatasetId
  created_at_ms : Int64
  edges : Array[LineageEdge]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn lineage_edge(
  from_id : String,
  to_id : String,
  relation : String,
) -> LineageEdge {
  { from_id, to_id, relation }
}

///|
pub fn lineage_manifest(
  lineage_id : String,
  root_dataset_id : DatasetId,
  created_at_ms : Int64,
  edges? : Array[LineageEdge] = [],
) -> LineageManifest {
  { lineage_id, root_dataset_id, created_at_ms, edges }
}
