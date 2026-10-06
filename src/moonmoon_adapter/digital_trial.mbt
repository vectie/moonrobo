///|
/// Imported digital evidence only. No field in this contract is device authority.
pub(all) struct DigitalTrialImport {
  trial_id : String
  session_id : String
  dossier_text : String
  result_text : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct DigitalTrialBinding {
  trial_id : String
  session_id : String
  attempt_id : String
  proof_id : String
  dossier_digest : String
  result_digest : String
  baseline_digest : String
  robot_id : String
  robot_revision : String
  profile_path : String
  profile_digest : String
  urdf_path : String
  urdf_digest : String
  validation_path : String
  validation_digest : String
  calibration : Json
  calibration_digest : String
  calibration_source_digest : String
  digital_result : String
  blockers : Array[String]
  limitations : Array[String]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct DigitalTrialEvent {
  trial_id : String
  expected_revision : Int
  event_id : String
  kind : String
  proof_text : String
  reviewer : String
  note : String
  now_ms : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn digital_digest(text : String) -> String {
  "sha256:" + @crypto.bytes_to_hex_string(@crypto.sha256(@utf8.encode(text)))
}

///|
pub fn digital_component(text : String) -> Bool {
  text.length() > 0 &&
  text.length() <= 100 &&
  text
  .iter()
  .all(c => {
    (c >= 'a' && c <= 'z') ||
    (c >= 'A' && c <= 'Z') ||
    c.is_ascii_digit() ||
    c == '-' ||
    c == '_'
  })
}

///|
pub fn digital_local_ref(text : String) -> Bool {
  !text.is_empty() &&
  !text.has_prefix("/") &&
  !text.contains("\\") &&
  !text.contains(":") &&
  text.split("/").all(part => part != "" && part != "." && part != "..")
}

///|
fn need(condition : Bool, message : String) -> Unit raise {
  if !condition {
    fail(message)
  }
}

///|
fn field(value : Json, name : String) -> Json raise {
  guard value is Object(fields) && fields.get(name) is Some(value) else {
    fail("Missing digital evidence field: " + name)
  }
  value
}

///|
fn string_field(value : Json, name : String) -> String raise {
  guard field(value, name) is String(text) && !text.trim().is_empty() else {
    fail("Expected nonempty digital evidence string: " + name)
  }
  text
}

///|
fn array_field(value : Json, name : String) -> Array[Json] raise {
  guard field(value, name) is Array(values) else {
    fail("Expected array: " + name)
  }
  values
}

///|
fn frozen_source(sources : Map[String, String], path : String) -> String raise {
  guard sources.get(path) is Some(text) else {
    fail("Missing frozen source: " + path)
  }
  text
}

///|
fn source_json(sources : Map[String, String], path : String) -> Json raise {
  @json.parse(frozen_source(sources, path))
}

///|
/// Checks receipt integrity and exact artifact identity; does not rerun science.
/// Keep result_text unchanged for proof and future incident export.
pub fn decode_digital_trial(
  request : DigitalTrialImport,
) -> DigitalTrialBinding raise {
  need(
    digital_component(request.trial_id) && digital_component(request.session_id),
    "Invalid trial/session identity",
  )
  need(
    @utf8.encode(request.dossier_text).length() <= 8388608 &&
    @utf8.encode(request.result_text).length() <= 1048576,
    "Digital import exceeds dossier/result limits",
  )
  let envelope = @json.parse(request.dossier_text)
  need(
    string_field(envelope, "contract_id") ==
    "moonmoon.mission-study-envelope.v1",
    "Unsupported MoonMoon envelope",
  )
  let dossier_text = string_field(envelope, "dossier_json")
  let dossier_digest = string_field(envelope, "dossier_digest")
  need(digital_digest(dossier_text) == dossier_digest, "Dossier bytes changed")
  let dossier = @json.parse(dossier_text)
  need(
    string_field(dossier, "contract_id") == "moonmoon.mission-study.v1" &&
    field(dossier, "physical_readiness") == false &&
    field(dossier, "review_required") == true,
    "Study must remain digital-only and reviewable",
  )
  let sources : Map[String, String] = Map([])
  let source_list = array_field(dossier, "sources")
  need(source_list.length() <= 64, "Too many frozen sources")
  for source in source_list {
    let path = string_field(source, "artifact_ref")
    let text = string_field(source, "text")
    need(
      digital_local_ref(path) && !sources.contains(path),
      "Invalid/duplicate frozen source",
    )
    need(
      @utf8.encode(text).length() <= 1048576 &&
      digital_digest(text) == string_field(source, "digest"),
      "Frozen source bytes changed: " + path,
    )
    sources[path] = text
  }
  let alternatives = array_field(dossier, "alternatives")
  let matches = alternatives.filter(item => {
    string_field(item, "session_id") == request.session_id
  })
  need(matches.length() == 1, "Select one exact MoonMoon session")
  let alternative = matches[0]
  let baseline_text = string_field(alternative, "baseline_json")
  let baseline_digest = string_field(alternative, "baseline_digest")
  need(
    digital_digest(baseline_text) == baseline_digest,
    "Baseline bytes changed",
  )
  let baseline = @json.parse(baseline_text)
  let result_ref = string_field(alternative, "result_ref")
  need(
    request.result_text == frozen_source(sources, result_ref),
    "Exported result does not match exact frozen result bytes",
  )
  let result_digest = digital_digest(request.result_text)
  need(
    result_digest == string_field(alternative, "result_digest"),
    "Result digest changed",
  )
  let result = @json.parse(request.result_text)
  need(
    field(result, "artifact_binding_verified") == true &&
    field(result, "terrain_source_verified") == true &&
    field(result, "deterministic_replay_required") == true,
    "Result does not retain verified digital artifact/terrain/replay assertions",
  )
  let design = source_json(sources, string_field(alternative, "design_ref"))
  let robot = field(design, "robot_artifact")
  let environment = field(design, "environment")
  let mission = field(design, "mission")
  let scenario = field(design, "scenario")
  need(
    string_field(result, "contract_id") == "moonmoon.robot-mission-result.v1" &&
    string_field(design, "contract_id") == "moonsuite.robot-design.v1",
    "Unsupported digital result/design",
  )
  need(
    field(result, "physical_readiness") == false &&
    field(result, "authority") == "digital-only" &&
    field(mission, "authority") == "digital-only" &&
    field(robot, "physical_transport_enabled") == false,
    "Digital evidence cannot grant device authority",
  )
  for key in ["design_id", "revision"] {
    need(
      field(result, key) == field(design, key),
      "Design/result identity mismatch: " + key,
    )
  }
  for key in ["robot_id", "robot_revision"] {
    need(
      field(result, key) == field(robot, key),
      "Robot/result identity mismatch: " + key,
    )
  }
  for key in ["scenario_id", "seed", "scenario_kind", "injected_faults"] {
    need(
      field(result, key) == field(scenario, key),
      "Scenario/result mismatch: " + key,
    )
  }
  need(
    field(result, "route_id") == field(mission, "route_id"),
    "Route identity mismatch",
  )
  for
    key in [
      "terrain_source_path", "whole_grid_status", "whole_grid_max_neighbor_grade_deg",
    ] {
    need(
      field(result, key) == field(environment, key),
      "Terrain identity mismatch: " + key,
    )
  }
  let calibration = field(environment, "calibration")
  for
    key in [
      "cell_size_m", "whole_grid_status", "whole_grid_max_neighbor_grade_deg",
    ] {
    need(
      field(baseline, key) == field(environment, key),
      "Baseline terrain/grid mismatch: " + key,
    )
  }
  need(
    field(baseline, "robot_artifact") == robot &&
    field(baseline, "calibration") == calibration &&
    field(baseline, "site") == field(dossier, "site"),
    "Baseline robot/calibration/site mismatch",
  )
  need(
    field(baseline, "terrain_digest") ==
    digital_digest(
      frozen_source(sources, string_field(environment, "terrain_source_path")),
    ).to_json(),
    "Terrain source changed",
  )
  let artifact_root = string_field(robot, "artifact_root")
  need(digital_local_ref(artifact_root), "Invalid artifact root")
  for
    (path_key, digest_key) in [
      ("robot_json_path", "robot_json_sha256"),
      ("robot_urdf_path", "robot_urdf_sha256"),
      ("validation_receipt_path", "validation_receipt_sha256"),
    ] {
    let path = string_field(robot, path_key)
    need(digital_local_ref(path), "Invalid robot artifact path")
    need(
      digital_digest(frozen_source(sources, artifact_root + "/" + path)) ==
      "sha256:" + string_field(robot, digest_key),
      "Robot artifact digest mismatch",
    )
  }
  let bridge = source_json(
    sources,
    artifact_root + "/" + string_field(robot, "bridge_config_path"),
  )
  need(
    field(bridge, "mode") == "simulation-only" &&
    field(bridge, "physical_transport_enabled") == false &&
    field(bridge, "design_id") == field(robot, "robot_id"),
    "Frozen bridge must remain simulation-only",
  )
  let profile = source_json(
    sources,
    artifact_root + "/" + string_field(robot, "robot_json_path"),
  )
  let validation = source_json(
    sources,
    artifact_root + "/" + string_field(robot, "validation_receipt_path"),
  )
  need(
    field(profile, "id") == field(robot, "robot_id") &&
    field(validation, "book_id") == field(robot, "robot_id") &&
    field(validation, "status") == "accepted" &&
    field(validation, "physical_transport_enabled") == false,
    "Profile/validation robot identity mismatch",
  )
  let provenance = source_json(
    sources,
    string_field(alternative, "provenance_ref"),
  )
  need(
    field(provenance, "contract_id") == "moonmoon.mission-provenance.v1" &&
    field(provenance, "session_id") == request.session_id.to_json() &&
    field(provenance, "result_ref") == result_ref.to_json(),
    "Provenance/result mismatch",
  )
  let integration = source_json(
    sources,
    string_field(provenance, "moonrobo_integration_receipt_ref"),
  )
  let output = field(integration, "output")
  need(
    field(integration, "contract_id") ==
    "moonrobo.digital-model-integration-receipt.v1" &&
    field(integration, "adapter_id") == "moonrobo-local-v1" &&
    field(integration, "operation_id") == "robot.integrate-digital-model" &&
    field(integration, "status") == "succeeded" &&
    field(integration, "physical_execution_performed") == false &&
    field(output, "accepted") == true &&
    field(output, "robobook_ref") == artifact_root.to_json(),
    "Frozen integration receipt is incompatible",
  )
  let model_ref = artifact_root + "/" + string_field(robot, "robot_urdf_path")
  let validation_ref = artifact_root +
    "/" +
    string_field(robot, "validation_receipt_path")
  let integration_refs : Array[String] = @json.from_json(
    field(integration, "evidence_refs"),
  )
  need(
    field(output, "model_ref") == model_ref.to_json() &&
    field(output, "validation_receipt_ref") == validation_ref.to_json() &&
    integration_refs.contains(model_ref) &&
    integration_refs.contains(validation_ref),
    "Integration receipt artifact references differ",
  )
  need(
    field(provenance, "mission_design_ref") == field(alternative, "design_ref") &&
    field(provenance, "replay_receipt_ref") == field(alternative, "replay_ref") &&
    field(provenance, "terrain_ref") ==
    field(environment, "terrain_source_path"),
    "Provenance artifact references differ",
  )
  let provenance_digests : Array[String] = @json.from_json(
    field(provenance, "source_digests"),
  )
  need(
    provenance_digests.length() >= 4 &&
    provenance_digests[0] ==
    digital_digest(
      frozen_source(
        sources,
        string_field(provenance, "moonrobo_integration_receipt_ref"),
      ),
    ) &&
    provenance_digests[1] ==
    digital_digest(
      frozen_source(sources, string_field(alternative, "design_ref")),
    ) &&
    provenance_digests[2] ==
    digital_digest(
      frozen_source(sources, string_field(environment, "terrain_source_path")),
    ) &&
    provenance_digests[3] == result_digest,
    "Provenance source digest mismatch",
  )
  let provenance_refs : Array[String] = @json.from_json(
    field(provenance, "source_refs"),
  )
  for reference in provenance_refs {
    let _ = frozen_source(sources, reference)
  }
  for dataset in array_field(provenance, "dataset_evidence") {
    need(
      field(dataset, "digest") ==
      digital_digest(
        frozen_source(sources, string_field(dataset, "evidence_ref")),
      ).to_json(),
      "Dataset evidence digest mismatch",
    )
  }
  let replay = source_json(sources, string_field(alternative, "replay_ref"))
  need(
    field(replay, "contract_id") == "moonmoon.mission-replay-receipt.v1" &&
    field(replay, "session_id") == request.session_id.to_json() &&
    field(replay, "design_id") == field(design, "design_id") &&
    field(replay, "scenario_id") == field(scenario, "scenario_id") &&
    field(replay, "seed") == field(scenario, "seed"),
    "Replay identity mismatch",
  )
  need(
    field(replay, "byte_equivalent") == true &&
    field(replay, "first_result_ref") == result_ref.to_json() &&
    field(replay, "first_result_digest") == result_digest.to_json() &&
    field(replay, "replay_result_digest") == result_digest.to_json() &&
    frozen_source(sources, string_field(replay, "replay_result_ref")) ==
    request.result_text,
    "Replay proof differs",
  )
  let required : Int = @json.from_json(field(replay, "required_replays"))
  let completed : Int = @json.from_json(field(replay, "completed_replays"))
  need(
    required >= 2 &&
    completed >= required &&
    field(result, "replay_count") == required.to_json() &&
    field(
      field(field(design, "verification_criteria"), "replay"),
      "required_runs",
    ) ==
    required.to_json(),
    "Replay count incomplete",
  )
  let evaluation = source_json(
    sources,
    string_field(alternative, "evaluation_ref"),
  )
  need(
    field(evaluation, "contract_id") == "moonmoon.mission-evaluation-report.v1" &&
    field(evaluation, "session_id") == request.session_id.to_json() &&
    field(evaluation, "physical_readiness") == false &&
    field(evaluation, "review_required") == true &&
    field(evaluation, "decision") == field(result, "result") &&
    field(evaluation, "blockers") == field(result, "blockers"),
    "Evaluation/result mismatch",
  )
  for key in ["design_id", "revision", "scenario_id", "seed"] {
    need(
      field(evaluation, key) == field(result, key),
      "Evaluation identity mismatch: " + key,
    )
  }
  need(
    field(evaluation, "result_ref") == result_ref.to_json() &&
    field(evaluation, "provenance_ref") == field(alternative, "provenance_ref") &&
    field(evaluation, "replay_receipt_ref") == field(alternative, "replay_ref") &&
    field(evaluation, "replay_verified") == true &&
    field(evaluation, "result_claim") == field(result, "evidence_claim"),
    "Evaluation receipt binding mismatch",
  )
  let calibration_ref = string_field(calibration, "authoritative_source")
  need(
    digital_local_ref(calibration_ref),
    "Invalid calibration evidence reference",
  )
  let calibration_source_digest = match sources.get(calibration_ref) {
    Some(text) => digital_digest(text)
    None => ""
  }
  need(
    field(calibration, "qualified") == false || calibration_source_digest != "",
    "Qualified calibration source is missing",
  )
  let digital_result = string_field(result, "result")
  need(
    digital_result == "accepted" || digital_result == "rejected",
    "Unknown result decision",
  )
  {
    trial_id: request.trial_id,
    session_id: request.session_id,
    attempt_id: request.trial_id + "-digital-import",
    proof_id: request.session_id + "-digital-result",
    dossier_digest,
    result_digest,
    baseline_digest,
    robot_id: string_field(robot, "robot_id"),
    robot_revision: string_field(robot, "robot_revision"),
    profile_path: string_field(robot, "robot_json_path"),
    profile_digest: "sha256:" + string_field(robot, "robot_json_sha256"),
    urdf_path: string_field(robot, "robot_urdf_path"),
    urdf_digest: "sha256:" + string_field(robot, "robot_urdf_sha256"),
    validation_path: string_field(robot, "validation_receipt_path"),
    validation_digest: "sha256:" +
    string_field(robot, "validation_receipt_sha256"),
    calibration,
    calibration_digest: digital_digest(calibration.stringify()),
    calibration_source_digest,
    digital_result,
    blockers: @json.from_json(field(result, "blockers")),
    limitations: @json.from_json(field(result, "limitations")),
  }
}
