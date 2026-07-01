///|
pub(all) struct MoonDataTransformQuery {
  input_dataset_id : String
  output_dataset_id : String
  status : String
  quality_run_id : String
  rejected_artifact_kind : String
  rejected_artifact_id : String
  lineage_id : String
  step_kind : String
  summary_contains : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataTransformList {
  root : String
  query : MoonDataTransformQuery
  transform_count : Int
  transforms : Array[@moondata_core.TransformRun]
  refs : Array[@moondata_core.MoonDataRef]
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn transform_query(
  input_dataset_id? : String = "",
  output_dataset_id? : String = "",
  status? : String = "",
  quality_run_id? : String = "",
  rejected_artifact_kind? : String = "",
  rejected_artifact_id? : String = "",
  lineage_id? : String = "",
  step_kind? : String = "",
  summary_contains? : String = "",
) -> MoonDataTransformQuery {
  {
    input_dataset_id,
    output_dataset_id,
    status,
    quality_run_id,
    rejected_artifact_kind,
    rejected_artifact_id,
    lineage_id,
    step_kind,
    summary_contains,
  }
}

///|
fn transform_query_has_filters(query : MoonDataTransformQuery) -> Bool {
  query.input_dataset_id != "" ||
  query.output_dataset_id != "" ||
  query.status != "" ||
  query.quality_run_id != "" ||
  query.rejected_artifact_kind != "" ||
  query.rejected_artifact_id != "" ||
  query.lineage_id != "" ||
  query.step_kind != "" ||
  query.summary_contains != ""
}

///|
fn rejected_refs_match(
  refs : Array[@moondata_core.MoonDataRef],
  artifact_kind : String,
  artifact_id : String,
) -> Bool {
  if artifact_kind == "" && artifact_id == "" {
    return true
  }
  for moondata_ref in refs {
    let kind_matches = artifact_kind == "" ||
      moondata_ref.artifact_kind == artifact_kind
    let id_matches = artifact_id == "" ||
      moondata_ref.artifact_id == artifact_id
    if kind_matches && id_matches {
      return true
    }
  }
  false
}

///|
fn transform_has_step_kind(
  steps : Array[@moondata_core.TransformStep],
  step_kind : String,
) -> Bool {
  if step_kind == "" {
    return true
  }
  for step in steps {
    if step.kind == step_kind {
      return true
    }
  }
  false
}

///|
fn transform_matches(
  run : @moondata_core.TransformRun,
  query : MoonDataTransformQuery,
) -> Bool {
  if query.input_dataset_id != "" &&
    run.input_dataset_id != query.input_dataset_id {
    return false
  }
  if query.output_dataset_id != "" &&
    run.output_dataset_id != query.output_dataset_id {
    return false
  }
  if query.status != "" && run.status != query.status {
    return false
  }
  if query.quality_run_id != "" &&
    !contains_id(run.quality_run_ids, query.quality_run_id) {
    return false
  }
  if query.lineage_id != "" && run.lineage_id != query.lineage_id {
    return false
  }
  if !rejected_refs_match(
      run.rejected_refs,
      query.rejected_artifact_kind,
      query.rejected_artifact_id,
    ) {
    return false
  }
  if !transform_has_step_kind(run.steps, query.step_kind) {
    return false
  }
  query.summary_contains == "" || run.summary.contains(query.summary_contains)
}

///|
fn transform_refs(
  root : String,
  transforms : Array[@moondata_core.TransformRun],
) -> Array[@moondata_core.MoonDataRef] {
  let refs : Array[@moondata_core.MoonDataRef] = []
  for run in transforms {
    refs.push(
      @moondata_core.moondata_ref(
        "transform-run",
        run.transform_run_id,
        @moondata_store.transform_run_path(root, run.transform_run_id),
        run.summary,
      ),
    )
  }
  refs
}

///|
pub fn list_transforms(
  root : String,
  query? : MoonDataTransformQuery = transform_query(),
) -> Result[MoonDataTransformList, @moondata_store.MoonDataStoreIssue] {
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let transforms : Array[@moondata_core.TransformRun] = []
  for entry in catalog.entries {
    if entry.artifact_kind == "transform-run" {
      let run = match
        @moondata_store.read_transform_run(root, entry.artifact_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let matches = if transform_query_has_filters(query) {
        transform_matches(run, query)
      } else {
        true
      }
      if matches {
        transforms.push(run)
      }
    }
  }
  let refs = transform_refs(root, transforms)
  Ok({
    root,
    query,
    transform_count: transforms.length(),
    transforms,
    refs,
    summary: "MoonData transforms: \{transforms.length()} match(es)",
  })
}
