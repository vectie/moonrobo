///|
pub fn review_annotation_set(
  annotation_set_id : @moondata_core.AnnotationSetId,
  target_refs : Array[@moondata_core.MoonDataRef],
  labels : Array[@moondata_core.AnnotationLabel],
  reviewer : String,
  created_at_ms : Int64,
  status? : String = "accepted",
  evidence_refs? : Array[@moondata_core.MoonDataRef] = [],
  summary? : String = "",
) -> @moondata_core.AnnotationSet {
  @moondata_core.annotation_set(
    annotation_set_id,
    target_refs,
    labels,
    reviewer,
    created_at_ms,
    status~,
    evidence_refs~,
    summary~,
  )
}

///|
pub fn target_ids(set : @moondata_core.AnnotationSet) -> Array[String] {
  let ids : Array[String] = []
  for target_ref in set.target_refs {
    ids.push(target_ref.artifact_id)
  }
  ids
}

///|
pub fn annotation_target_index_id(
  annotation_set_id : @moondata_core.AnnotationSetId,
) -> @moondata_core.AnnotationTargetIndexId {
  "annotation-target-\{annotation_set_id}"
}

///|
fn push_unique(values : Array[String], value : String) -> Unit {
  for candidate in values {
    if candidate == value {
      return
    }
  }
  values.push(value)
}

///|
pub fn review_target_index(
  annotation_index_id : @moondata_core.AnnotationTargetIndexId,
  set : @moondata_core.AnnotationSet,
) -> @moondata_core.AnnotationTargetIndex {
  let label_keys : Array[String] = []
  let label_values : Array[String] = []
  for label in set.labels {
    push_unique(label_keys, label.key)
    push_unique(label_values, label.value)
  }
  @moondata_core.annotation_target_index(
    annotation_index_id,
    set.annotation_set_id,
    set.target_refs,
    set.reviewer,
    set.status,
    set.created_at_ms,
    label_keys~,
    label_values~,
    summary=set.summary,
  )
}
