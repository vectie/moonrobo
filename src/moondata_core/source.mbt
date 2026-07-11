///|
pub(all) struct DataSource {
  source_id : SourceId
  kind : String
  label : String
  robot_id : String
  bridge_id : String
  origin_uri : String
  created_at_ms : Int64
  source_refs : Array[DataRef]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn data_source(
  source_id : SourceId,
  kind : String,
  label : String,
  robot_id : String,
  bridge_id : String,
  origin_uri : String,
  created_at_ms : Int64,
  source_refs? : Array[DataRef] = [],
) -> DataSource {
  {
    source_id,
    kind,
    label,
    robot_id,
    bridge_id,
    origin_uri,
    created_at_ms,
    source_refs,
  }
}
