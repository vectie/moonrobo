///|
pub(all) struct MoonDataRobotModelQuery {
  model_id_contains : String
  robot_id : String
  format : String
  status : String
  validation_status : String
  data_kind : String
  link_name : String
  joint_name : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataRobotModelList {
  root : String
  query : MoonDataRobotModelQuery
  model_count : Int
  data_ref_count : Int
  total_model_byte_count : Int64
  model_checksums : Array[String]
  latest_model_id : String
  latest_model_created_at_ms : Int64
  models : Array[@moondata_core.RobotModelManifest]
  refs : Array[@moondata_core.MoonDataRef]
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn robot_model_query(
  model_id_contains? : String = "",
  robot_id? : String = "",
  format? : String = "",
  status? : String = "",
  validation_status? : String = "",
  data_kind? : String = "",
  link_name? : String = "",
  joint_name? : String = "",
) -> MoonDataRobotModelQuery {
  {
    model_id_contains,
    robot_id,
    format,
    status,
    validation_status,
    data_kind,
    link_name,
    joint_name,
  }
}

///|
fn robot_model_query_has_filters(query : MoonDataRobotModelQuery) -> Bool {
  query.model_id_contains != "" ||
  query.robot_id != "" ||
  query.format != "" ||
  query.status != "" ||
  query.validation_status != "" ||
  query.data_kind != "" ||
  query.link_name != "" ||
  query.joint_name != ""
}

///|
fn data_ref_array_has_kind(
  data_refs : Array[@moondata_core.DataRef],
  data_kind : String,
) -> Bool {
  for data_ref in data_refs {
    if data_ref.kind == data_kind {
      return true
    }
  }
  false
}

///|
fn robot_model_has_data_kind(
  model : @moondata_core.RobotModelManifest,
  data_kind : String,
) -> Bool {
  data_kind == "" ||
  model.urdf_ref.kind == data_kind ||
  data_ref_array_has_kind(model.mesh_refs, data_kind) ||
  data_ref_array_has_kind(model.material_refs, data_kind)
}

///|
fn string_array_contains(values : Array[String], value : String) -> Bool {
  if value == "" {
    return true
  }
  for current in values {
    if current == value {
      return true
    }
  }
  false
}

///|
fn robot_model_matches(
  model : @moondata_core.RobotModelManifest,
  query : MoonDataRobotModelQuery,
) -> Bool {
  if query.model_id_contains != "" &&
    !model.model_id.contains(query.model_id_contains) {
    return false
  }
  if query.robot_id != "" && model.robot_id != query.robot_id {
    return false
  }
  if query.format != "" && model.format != query.format {
    return false
  }
  if query.status != "" && model.status != query.status {
    return false
  }
  if query.validation_status != "" &&
    model.validation_status != query.validation_status {
    return false
  }
  if !robot_model_has_data_kind(model, query.data_kind) {
    return false
  }
  if !string_array_contains(model.link_names, query.link_name) {
    return false
  }
  string_array_contains(model.joint_names, query.joint_name)
}

///|
fn robot_model_refs(
  root : String,
  models : Array[@moondata_core.RobotModelManifest],
) -> Array[@moondata_core.MoonDataRef] {
  let refs : Array[@moondata_core.MoonDataRef] = []
  for model in models {
    refs.push(
      @moondata_core.moondata_ref(
        "robot-model",
        model.model_id,
        @moondata_store.robot_model_path(root, model.model_id),
        "\{model.robot_id} \{model.format} \{model.validation_status}",
      ),
    )
  }
  refs
}

///|
priv struct RobotModelListSummary {
  data_ref_count : Int
  total_model_byte_count : Int64
  model_checksums : Array[String]
  latest_model_id : String
  latest_model_created_at_ms : Int64
}

///|
fn robot_model_list_summary(
  models : Array[@moondata_core.RobotModelManifest],
) -> RobotModelListSummary {
  let mut data_ref_count = 0
  let mut total_model_byte_count = 0L
  let model_checksums : Array[String] = []
  let mut latest_model_id = ""
  let mut latest_model_created_at_ms = -1L
  for model in models {
    data_ref_count += 1
    total_model_byte_count += model.urdf_ref.byte_count
    push_unique_checksum(model_checksums, model.urdf_ref.checksum)
    for data_ref in model.mesh_refs {
      data_ref_count += 1
      total_model_byte_count += data_ref.byte_count
      push_unique_checksum(model_checksums, data_ref.checksum)
    }
    for data_ref in model.material_refs {
      data_ref_count += 1
      total_model_byte_count += data_ref.byte_count
      push_unique_checksum(model_checksums, data_ref.checksum)
    }
    if model.created_at_ms > latest_model_created_at_ms {
      latest_model_id = model.model_id
      latest_model_created_at_ms = model.created_at_ms
    }
  }
  if latest_model_id == "" {
    {
      data_ref_count,
      total_model_byte_count,
      model_checksums,
      latest_model_id: "",
      latest_model_created_at_ms: 0L,
    }
  } else {
    {
      data_ref_count,
      total_model_byte_count,
      model_checksums,
      latest_model_id,
      latest_model_created_at_ms,
    }
  }
}

///|
pub fn list_robot_models(
  root : String,
  query? : MoonDataRobotModelQuery = robot_model_query(),
) -> Result[MoonDataRobotModelList, @moondata_store.MoonDataStoreIssue] {
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let models : Array[@moondata_core.RobotModelManifest] = []
  for entry in catalog.entries {
    if entry.artifact_kind == "robot-model" {
      let model = match
        @moondata_store.read_robot_model(root, entry.artifact_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let matches = if robot_model_query_has_filters(query) {
        robot_model_matches(model, query)
      } else {
        true
      }
      if matches {
        models.push(model)
      }
    }
  }
  let refs = robot_model_refs(root, models)
  let evidence = robot_model_list_summary(models)
  Ok({
    root,
    query,
    model_count: models.length(),
    data_ref_count: evidence.data_ref_count,
    total_model_byte_count: evidence.total_model_byte_count,
    model_checksums: evidence.model_checksums,
    latest_model_id: evidence.latest_model_id,
    latest_model_created_at_ms: evidence.latest_model_created_at_ms,
    models,
    refs,
    summary: "MoonData robot models: \{models.length()} match(es), \{evidence.data_ref_count} data ref(s), \{evidence.total_model_byte_count} byte(s), latest \{evidence.latest_model_id}",
  })
}
