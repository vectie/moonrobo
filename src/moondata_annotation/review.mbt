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
