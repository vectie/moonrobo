///|
pub(all) struct DataRef {
  ref_id : DataRefId
  kind : String
  uri : String
  content_type : String
  byte_count : Int64
  checksum : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn data_ref(
  ref_id : DataRefId,
  kind : String,
  uri : String,
  content_type? : String = "application/octet-stream",
  byte_count? : Int64 = 0L,
  checksum? : String = "",
) -> DataRef {
  { ref_id, kind, uri, content_type, byte_count, checksum }
}

///|
pub(all) struct MoonDataRef {
  artifact_kind : String
  artifact_id : String
  manifest_path : String
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn moondata_ref(
  artifact_kind : String,
  artifact_id : String,
  manifest_path : String,
  summary : String,
) -> MoonDataRef {
  { artifact_kind, artifact_id, manifest_path, summary }
}
