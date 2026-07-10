///|
pub(all) struct RecorderPlan {
  schema_version : String
  root : String
  session_id : String
  robot_id : String
  bridge_id : String
  output_dir : String
  script_path : String
  log_path : String
  topics : Array[String]
  all_topics : Bool
  max_bag_size_bytes : Int64
  max_bag_duration_seconds : Int64
  max_cache_size_bytes : Int64
  max_bag_files : Int
  minimum_free_bytes : Int64
  command : Array[String]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RecorderChunk {
  name : String
  path : String
  byte_count : Int64
  finalized : Bool
  recovery_required : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RecorderSealResult {
  schema_version : String
  session : RecorderSession
  captures : Array[RecorderSealedChunk]
  sealed_count : Int
  recovery_required_paths : Array[String]
  recovery_required_count : Int
  invalid_paths : Array[String]
  invalid_count : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RecorderSealedChunk {
  name : String
  path : String
  capture_id : String
  dataset_id : String
  episode_id : String
  blob_uri : String
  checksum : String
  byte_count : Int64
  existed : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RecorderSession {
  schema_version : String
  session_id : String
  status : String
  pid : Int
  running : Bool
  revision : Int
  created_at_ms : Int64
  updated_at_ms : Int64
  started_at_ms : Int64
  stopped_at_ms : Int64
  available_bytes : Int64
  disk_pressure : Bool
  message_loss_status : String
  messages_lost : Int64
  chunks : Array[RecorderChunk]
  plan : RecorderPlan
  message : String
} derive(Debug, Eq, ToJson, FromJson)
