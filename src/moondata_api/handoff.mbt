///|
pub(all) struct MoonDataHandoff {
  root : String
  version_id : @moondata_core.DatasetVersionId
  status : MoonDataStatus
  context : MoonDataContext
  artifacts : MoonDataArtifactList
  lineage : MoonDataLineageGraph
  slice : MoonDataDatasetSlice?
  refs : Array[@moondata_core.MoonDataRef]
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
fn push_unique_ref(
  refs : Array[@moondata_core.MoonDataRef],
  candidate : @moondata_core.MoonDataRef,
) -> Unit {
  for existing in refs {
    if existing.artifact_kind == candidate.artifact_kind &&
      existing.artifact_id == candidate.artifact_id {
      return
    }
  }
  refs.push(candidate)
}

///|
fn add_refs(
  refs : Array[@moondata_core.MoonDataRef],
  candidates : Array[@moondata_core.MoonDataRef],
) -> Unit {
  for candidate in candidates {
    push_unique_ref(refs, candidate)
  }
}

///|
fn handoff_refs(
  context : MoonDataContext,
  artifacts : MoonDataArtifactList,
  lineage : MoonDataLineageGraph,
  slice : MoonDataDatasetSlice?,
) -> Array[@moondata_core.MoonDataRef] {
  let refs : Array[@moondata_core.MoonDataRef] = []
  add_refs(refs, context.refs)
  add_refs(refs, artifacts.refs)
  add_refs(refs, lineage.refs)
  match slice {
    Some(value) => add_refs(refs, value.refs)
    None => ()
  }
  refs
}

///|
fn handoff_summary(
  status : MoonDataStatus,
  lineage : MoonDataLineageGraph,
  slice : MoonDataDatasetSlice?,
) -> String {
  let slice_text = match slice {
    Some(value) => "slice \{value.version_id} \{value.status}"
    None => "no version slice"
  }
  "MoonData handoff: \{status.entry_count} cataloged artifact(s), validation \{status.latest_validation_status}, \{lineage.lineage_count} lineage graph(s), \{slice_text}"
}

///|
pub fn read_handoff(
  root : String,
  version_id? : @moondata_core.DatasetVersionId = "",
) -> Result[MoonDataHandoff, @moondata_store.MoonDataStoreIssue] {
  let status = match read_status(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let artifacts = match list_artifacts(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let lineage = match read_lineage_graph(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let slice = if version_id == "" {
    None
  } else {
    match read_dataset_slice(root, version_id) {
      Ok(value) => Some(value)
      Err(error) => return Err(error)
    }
  }
  let context = context_from_status(status)
  let refs = handoff_refs(context, artifacts, lineage, slice)
  Ok({
    root,
    version_id,
    status,
    context,
    artifacts,
    lineage,
    slice,
    refs,
    summary: handoff_summary(status, lineage, slice),
  })
}
