///|
pub(all) struct ReplayAnnotation {
  annotation_id : String
  session_id : String
  frame_id : String
  label : String
  note : String
  severity : String
  created_by : @core.Requester
  created_at_ms : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn replay_annotation(
  annotation_id : String,
  session_id : String,
  frame_id : String,
  label : String,
  note : String,
  severity : String,
  created_by : @core.Requester,
  created_at_ms : Int64,
) -> ReplayAnnotation {
  {
    annotation_id,
    session_id,
    frame_id,
    label,
    note,
    severity,
    created_by,
    created_at_ms,
  }
}

///|
pub fn annotation_json(
  annotation : ReplayAnnotation,
  indent? : Int = 2,
) -> String {
  annotation.to_json().stringify(indent~)
}
