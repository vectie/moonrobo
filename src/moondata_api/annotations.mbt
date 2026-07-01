///|
pub(all) struct MoonDataAnnotationQuery {
  artifact_kind : String
  artifact_id : String
  reviewer : String
  status : String
  label_key : String
  label_value : String
  task_id : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataAnnotationList {
  root : String
  query : MoonDataAnnotationQuery
  annotation_count : Int
  label_count : Int
  target_ref_count : Int
  evidence_ref_count : Int
  latest_annotation_set_id : String
  latest_annotation_created_at_ms : Int64
  annotations : Array[MoonDataAnnotationView]
  refs : Array[@moondata_core.MoonDataRef]
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn annotation_query(
  artifact_kind? : String = "",
  artifact_id? : String = "",
  reviewer? : String = "",
  status? : String = "",
  label_key? : String = "",
  label_value? : String = "",
  task_id? : String = "",
) -> MoonDataAnnotationQuery {
  {
    artifact_kind,
    artifact_id,
    reviewer,
    status,
    label_key,
    label_value,
    task_id,
  }
}

///|
fn query_has_filters(query : MoonDataAnnotationQuery) -> Bool {
  query.artifact_kind != "" ||
  query.artifact_id != "" ||
  query.reviewer != "" ||
  query.status != "" ||
  query.label_key != "" ||
  query.label_value != "" ||
  query.task_id != ""
}

///|
fn label_matches(
  labels : Array[@moondata_core.AnnotationLabel],
  query : MoonDataAnnotationQuery,
) -> Bool {
  if query.label_key == "" && query.label_value == "" {
    return true
  }
  for label in labels {
    let key_matches = query.label_key == "" || label.key == query.label_key
    let value_matches = query.label_value == "" ||
      label.value == query.label_value
    if key_matches && value_matches {
      return true
    }
  }
  false
}

///|
fn refs_match_artifact(
  refs : Array[@moondata_core.MoonDataRef],
  query : MoonDataAnnotationQuery,
) -> Bool {
  if query.artifact_kind == "" && query.artifact_id == "" {
    return true
  }
  for moondata_ref in refs {
    let kind_matches = query.artifact_kind == "" ||
      moondata_ref.artifact_kind == query.artifact_kind
    let id_matches = query.artifact_id == "" ||
      moondata_ref.artifact_id == query.artifact_id
    if kind_matches && id_matches {
      return true
    }
  }
  false
}

///|
fn ref_task_matches(
  root : String,
  moondata_ref : @moondata_core.MoonDataRef,
  task_id : String,
) -> Result[Bool, @moondata_store.MoonDataStoreIssue] {
  match moondata_ref.artifact_kind {
    "episode" => {
      let episode = match
        @moondata_store.read_episode(root, moondata_ref.artifact_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      Ok(episode.task_id == task_id)
    }
    "frame" => {
      let frame = match
        @moondata_store.read_frame(root, moondata_ref.artifact_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let episode = match @moondata_store.read_episode(root, frame.episode_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      Ok(episode.task_id == task_id)
    }
    "task" => Ok(moondata_ref.artifact_id == task_id)
    _ => Ok(false)
  }
}

///|
fn refs_match_task(
  root : String,
  refs : Array[@moondata_core.MoonDataRef],
  task_id : String,
) -> Result[Bool, @moondata_store.MoonDataStoreIssue] {
  if task_id == "" {
    return Ok(true)
  }
  for moondata_ref in refs {
    let matches = match ref_task_matches(root, moondata_ref, task_id) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if matches {
      return Ok(true)
    }
  }
  Ok(false)
}

///|
fn annotation_matches(
  root : String,
  set : @moondata_core.AnnotationSet,
  query : MoonDataAnnotationQuery,
) -> Result[Bool, @moondata_store.MoonDataStoreIssue] {
  if query.reviewer != "" && set.reviewer != query.reviewer {
    return Ok(false)
  }
  if query.status != "" && set.status != query.status {
    return Ok(false)
  }
  if !label_matches(set.labels, query) {
    return Ok(false)
  }
  if !refs_match_artifact(set.target_refs, query) &&
    !refs_match_artifact(set.evidence_refs, query) {
    return Ok(false)
  }
  let target_task_matches = match
    refs_match_task(root, set.target_refs, query.task_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if target_task_matches {
    return Ok(true)
  }
  refs_match_task(root, set.evidence_refs, query.task_id)
}

///|
fn annotation_refs(
  root : String,
  annotations : Array[MoonDataAnnotationView],
) -> Array[@moondata_core.MoonDataRef] {
  let refs : Array[@moondata_core.MoonDataRef] = []
  for annotation in annotations {
    refs.push(
      @moondata_core.moondata_ref(
        "annotation-set",
        annotation.annotation_set_id,
        @moondata_store.annotation_set_path(root, annotation.annotation_set_id),
        annotation.summary,
      ),
    )
  }
  refs
}

///|
priv struct AnnotationListSummary {
  label_count : Int
  target_ref_count : Int
  evidence_ref_count : Int
  latest_annotation_set_id : String
  latest_annotation_created_at_ms : Int64
}

///|
fn annotation_list_summary(
  annotations : Array[MoonDataAnnotationView],
) -> AnnotationListSummary {
  let mut label_count = 0
  let mut target_ref_count = 0
  let mut evidence_ref_count = 0
  let mut latest_id = ""
  let mut latest_created_at_ms = -1L
  for annotation in annotations {
    label_count += annotation.labels.length()
    target_ref_count += annotation.target_refs.length()
    evidence_ref_count += annotation.evidence_refs.length()
    if annotation.created_at_ms > latest_created_at_ms {
      latest_id = annotation.annotation_set_id
      latest_created_at_ms = annotation.created_at_ms
    }
  }
  if latest_id == "" {
    return {
      label_count,
      target_ref_count,
      evidence_ref_count,
      latest_annotation_set_id: "",
      latest_annotation_created_at_ms: 0L,
    }
  }
  {
    label_count,
    target_ref_count,
    evidence_ref_count,
    latest_annotation_set_id: latest_id,
    latest_annotation_created_at_ms: latest_created_at_ms,
  }
}

///|
pub fn list_annotations(
  root : String,
  query? : MoonDataAnnotationQuery = annotation_query(),
) -> Result[MoonDataAnnotationList, @moondata_store.MoonDataStoreIssue] {
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let annotations : Array[MoonDataAnnotationView] = []
  for entry in catalog.entries {
    if entry.artifact_kind == "annotation-set" {
      let set = match
        @moondata_store.read_annotation_set(root, entry.artifact_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let matches = if query_has_filters(query) {
        match annotation_matches(root, set, query) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
      } else {
        true
      }
      if matches {
        annotations.push(annotation_view(set))
      }
    }
  }
  let refs = annotation_refs(root, annotations)
  let evidence = annotation_list_summary(annotations)
  Ok({
    root,
    query,
    annotation_count: annotations.length(),
    label_count: evidence.label_count,
    target_ref_count: evidence.target_ref_count,
    evidence_ref_count: evidence.evidence_ref_count,
    latest_annotation_set_id: evidence.latest_annotation_set_id,
    latest_annotation_created_at_ms: evidence.latest_annotation_created_at_ms,
    annotations,
    refs,
    summary: "MoonData annotations: \{annotations.length()} match(es), \{evidence.label_count} label(s), \{evidence.target_ref_count} target ref(s), \{evidence.evidence_ref_count} evidence ref(s), latest \{evidence.latest_annotation_set_id}",
  })
}
