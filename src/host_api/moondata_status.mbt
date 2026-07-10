///|
pub(all) struct MoonDataCockpitArtifact {
  artifact_kind : String
  artifact_id : String
  manifest_path : String
  status : String
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataCockpitStatus {
  root : String
  catalog_path : String
  initialized : Bool
  status : String
  ready : Bool
  artifact_count : Int
  dataset_count : Int
  capture_count : Int
  episode_count : Int
  frame_count : Int
  robot_model_count : Int
  quality_count : Int
  version_count : Int
  replay_count : Int
  export_count : Int
  validation_status : String
  blocker_count : Int
  warning_count : Int
  repair_open_count : Int
  artifacts : Array[MoonDataCockpitArtifact]
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn moondata_status_path() -> String {
  "/api/moondata/status"
}

///|
pub fn moondata_root_for_robobook(root : String) -> String {
  @runtime.robobook_path(root, "moondata")
}

///|
fn moondata_artifact_rows(
  entries : Array[@moondata_core.CatalogEntry],
) -> Array[MoonDataCockpitArtifact] {
  let rows : Array[MoonDataCockpitArtifact] = []
  for index in 0..<entries.length() {
    if index < 40 {
      let entry = entries[index]
      rows.push({
        artifact_kind: entry.artifact_kind,
        artifact_id: entry.artifact_id,
        manifest_path: entry.manifest_path,
        status: entry.status,
        summary: entry.summary,
      })
    }
  }
  rows
}

///|
fn moondata_not_initialized(root : String) -> MoonDataCockpitStatus {
  let data_root = moondata_root_for_robobook(root)
  {
    root: data_root,
    catalog_path: @moondata_store.catalog_path(data_root),
    initialized: false,
    status: "not-initialized",
    ready: false,
    artifact_count: 0,
    dataset_count: 0,
    capture_count: 0,
    episode_count: 0,
    frame_count: 0,
    robot_model_count: 0,
    quality_count: 0,
    version_count: 0,
    replay_count: 0,
    export_count: 0,
    validation_status: "missing",
    blocker_count: 0,
    warning_count: 0,
    repair_open_count: 0,
    artifacts: [],
    message: "MoonData is not initialized for this robot workspace.",
  }
}

///|
pub fn moondata_cockpit_status(
  root : String,
) -> Result[MoonDataCockpitStatus, @moondata_store.MoonDataStoreIssue] {
  let data_root = moondata_root_for_robobook(root)
  if !@fsx.path_exists(@moondata_store.catalog_path(data_root)) {
    return Ok(moondata_not_initialized(root))
  }
  let status = match @moondata_api.read_status(data_root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let inventory = match @moondata_api.list_artifacts(data_root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    root: data_root,
    catalog_path: status.catalog_path,
    initialized: true,
    status: if status.ready {
      "ready"
    } else {
      "attention"
    },
    ready: status.ready,
    artifact_count: status.entry_count,
    dataset_count: status.dataset_count,
    capture_count: status.capture_count,
    episode_count: status.episode_count,
    frame_count: status.frame_count,
    robot_model_count: status.robot_model_count,
    quality_count: status.quality_count,
    version_count: status.version_count,
    replay_count: status.replay_count,
    export_count: status.export_count,
    validation_status: status.latest_validation_status,
    blocker_count: status.latest_validation_blocker_count,
    warning_count: status.latest_validation_warning_count,
    repair_open_count: status.repair_open_count,
    artifacts: moondata_artifact_rows(inventory.artifacts),
    message: if status.ready {
      "MoonData is validated and ready for bounded suite reads."
    } else {
      "MoonData needs validation or repair work before handoff."
    },
  })
}

///|
pub fn moondata_status_response(root : String) -> HostApiResponse {
  match moondata_cockpit_status(root) {
    Ok(status) => json_response(200, status.to_json())
    Err(error) => error_response(500, error.code, error.path, error.message)
  }
}
