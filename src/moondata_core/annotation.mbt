///|
pub(all) struct AnnotationLabel {
  key : String
  value : String
  confidence : Double
  source : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn annotation_label(
  key : String,
  value : String,
  confidence? : Double = 1.0,
  source? : String = "human",
) -> AnnotationLabel {
  { key, value, confidence, source }
}

///|
pub(all) struct AnnotationSet {
  annotation_set_id : AnnotationSetId
  target_refs : Array[MoonDataRef]
  labels : Array[AnnotationLabel]
  reviewer : String
  status : String
  created_at_ms : Int64
  evidence_refs : Array[MoonDataRef]
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn annotation_set(
  annotation_set_id : AnnotationSetId,
  target_refs : Array[MoonDataRef],
  labels : Array[AnnotationLabel],
  reviewer : String,
  created_at_ms : Int64,
  status? : String = "draft",
  evidence_refs? : Array[MoonDataRef] = [],
  summary? : String = "",
) -> AnnotationSet {
  {
    annotation_set_id,
    target_refs,
    labels,
    reviewer,
    status,
    created_at_ms,
    evidence_refs,
    summary,
  }
}

///|
pub(all) struct AnnotationTargetIndex {
  annotation_index_id : AnnotationTargetIndexId
  annotation_set_id : AnnotationSetId
  target_refs : Array[MoonDataRef]
  label_keys : Array[String]
  label_values : Array[String]
  reviewer : String
  status : String
  created_at_ms : Int64
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn annotation_target_index(
  annotation_index_id : AnnotationTargetIndexId,
  annotation_set_id : AnnotationSetId,
  target_refs : Array[MoonDataRef],
  reviewer : String,
  status : String,
  created_at_ms : Int64,
  label_keys? : Array[String] = [],
  label_values? : Array[String] = [],
  summary? : String = "",
) -> AnnotationTargetIndex {
  {
    annotation_index_id,
    annotation_set_id,
    target_refs,
    label_keys,
    label_values,
    reviewer,
    status,
    created_at_ms,
    summary,
  }
}
