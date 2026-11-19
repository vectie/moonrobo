///|
pub fn learning_experiments_path() -> String {
  "/api/moondata/learning-experiments"
}

///|
pub fn learning_physics_response(
  root : String,
  path : String,
) -> HostApiResponse {
  let prefix = learning_experiments_path() + "/"
  guard path.has_prefix(prefix) else {
    return error_response(404, "not-found", path, "No learning physics route")
  }
  let parts = path[prefix.length():].split("/").to_array()
  guard (parts.length() == 3 || parts.length() == 4) && parts[1] == "physics" else {
    return error_response(
      404, "not-found", path, "Expected experiment/physics/seed",
    )
  }
  let seed = @string.parse_int(parts[2].to_owned()) catch {
    _ =>
      return error_response(
        400, "invalid-seed", path, "Expected an integer seed",
      )
  }
  match
    @moondata_learning.read_physics(
      moondata_root_for_robobook(root),
      parts[0].to_owned(),
      seed,
      mode=if parts.length() == 4 { parts[3].to_owned() } else { "original" },
    ) {
    Ok(evidence) => json_response(200, evidence.to_json())
    Err(message) =>
      error_response(400, "learning-evidence-unavailable", path, message)
  }
}

///|
/// Project registered simulation evidence with its source robot ownership.
pub fn learning_experiments_response(root : String) -> HostApiResponse {
  let data_root = moondata_root_for_robobook(root)
  let initialized = @fsx.path_exists(@moondata_store.catalog_path(data_root))
  let experiments = if initialized {
    match @moondata_learning.list(data_root) {
      Ok(values) => values
      Err(message) =>
        return error_response(500, "learning-read-failed", data_root, message)
    }
  } else {
    []
  }
  // Ownership comes from registered source manifests, not experiment names.
  // Missing sources stay unassigned so clients cannot mix robot workspaces.
  let experiment_robot_ids : Map[String, String] = {}
  for experiment in experiments {
    match @moondata_store.read_source(data_root, experiment.source_id) {
      Ok(source) =>
        experiment_robot_ids[experiment.experiment_id] = source.robot_id
      Err(_) => ()
    }
  }
  json_response(200, {
    "root": data_root.to_json(),
    "initialized": initialized.to_json(),
    "experiments": experiments.to_json(),
    "experiment_robot_ids": experiment_robot_ids.to_json(),
    "replay_experiment_ids": experiments
    .filter(experiment => {
      @moondata_learning.has_replay(data_root, experiment.experiment_id)
    })
    .map(experiment => experiment.experiment_id)
    .to_json(),
    "physical_execution_allowed": false.to_json(),
  })
}
