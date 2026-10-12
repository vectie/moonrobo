///|
/// Same frozen text-source shape used by MoonMoon mission studies.
pub(all) struct SimulationSource {
  artifact_ref : String
  digest : String
  text : String
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Field names and bare lowercase SHA256 values match MoonMoon's
/// robot_mission.RobotArtifactBinding. This is input, never a simulation result.
pub(all) struct RobotArtifactBinding {
  robot_id : String
  robot_revision : String
  artifact_root : String
  robot_json_path : String
  robot_urdf_path : String
  validation_receipt_path : String
  bridge_config_path : String
  robot_json_sha256 : String
  robot_urdf_sha256 : String
  validation_receipt_sha256 : String
  validation_status : String
  physical_transport_enabled : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SimulationInput {
  contract_id : String
  design_id : String
  revision : String
  design_ref : String
  integration_receipt_ref : String
  robot_artifact : RobotArtifactBinding
  sources : Array[SimulationSource]
  review_required : Bool
  physical_execution_allowed : Bool
  limitations : Array[String]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SimulationEnvelope {
  contract_id : String
  package_digest : String
  package_json : String
} derive(Debug, Eq, ToJson, FromJson)

///|
fn generated_files() -> Array[String] {
  [
    "robot.json", "model/robot.urdf", "bridge/bridge.json", "safety/policy.json",
    "design/robot-design.json", "design/build-receipt.json", "design/validation-receipt.json",
    "design/integration-receipt.json",
  ]
}

///|
fn artifact_ref(id : String, revision : String) -> String {
  "books/" + id + "/" + revision
}

///|
fn source(
  sources : Array[SimulationSource],
  reference : String,
) -> SimulationSource raise WorkbenchError {
  for item in sources {
    if item.artifact_ref == reference {
      return item
    }
  }
  raise WorkbenchError("Missing source: " + reference)
}

///|
fn robot_binding(
  id : String,
  revision : String,
  sources : Array[SimulationSource],
) -> RobotArtifactBinding raise WorkbenchError {
  let ref = artifact_ref(id, revision)
  {
    robot_id: id,
    robot_revision: revision,
    artifact_root: ref,
    robot_json_path: "robot.json",
    robot_urdf_path: "model/robot.urdf",
    validation_receipt_path: "design/validation-receipt.json",
    bridge_config_path: "bridge/bridge.json",
    robot_json_sha256: source(sources, ref + "/robot.json").digest[7:].to_owned(),
    robot_urdf_sha256: source(sources, ref + "/model/robot.urdf").digest[7:].to_owned(),
    validation_receipt_sha256: source(
      sources,
      ref + "/design/validation-receipt.json",
    ).digest[7:].to_owned(),
    validation_status: "accepted",
    physical_transport_enabled: false,
  }
}

///|
/// Read-only re-open validates the frozen manifest and all current source bytes.
/// It deliberately does not rerun validate_robobook (which rewrites its receipt).
pub fn export_input(
  root : String,
  id : String,
  revision : String,
  expected_digest : String,
) -> SimulationEnvelope raise WorkbenchError {
  let draft = load_draft(root, id, revision)
  require(
    draft.design_digest == expected_digest,
    "Draft changed or stale selection; re-open the selected revision",
  )
  let path = revision_root(root, id, revision) + "/build"
  let envelope : SimulationEnvelope = decode(read(path + "/package.json"))
  require(
    envelope.contract_id == "moonrobo.simulation-input-envelope.v1" &&
    envelope.package_digest ==
    @moondata_core.text_checksum(envelope.package_json),
    "Simulation package digest mismatch",
  )
  let packet : SimulationInput = decode(envelope.package_json)
  let ref = artifact_ref(id, revision)
  require(
    packet.contract_id == "moonrobo.simulation-input.v1" &&
    packet.design_id == id &&
    packet.revision == revision &&
    packet.review_required &&
    !packet.physical_execution_allowed,
    "Simulation package identity or authority mismatch",
  )
  require(
    packet.design_ref == ref + "/design/robot-design.json" &&
    packet.integration_receipt_ref == ref + "/design/integration-receipt.json",
    "Simulation package references mismatch",
  )
  let files = generated_files()
  require(
    packet.sources.length() == files.length(),
    "Simulation package source count mismatch",
  )
  for file in files {
    let frozen = source(packet.sources, ref + "/" + file)
    require(
      frozen.digest == @moondata_core.text_checksum(frozen.text),
      "Frozen source digest mismatch: " + file,
    )
    require(
      frozen.text == read(path + "/artifact/" + file),
      "Built source changed: " + file,
    )
  }
  require(
    source(packet.sources, packet.design_ref).text == draft.design_text,
    "Built design differs from saved draft",
  )
  require(
    packet.robot_artifact == robot_binding(id, revision, packet.sources),
    "Robot artifact binding mismatch",
  )
  envelope
}

///|
pub fn build_revision(
  root : String,
  id : String,
  revision : String,
  expected_digest : String,
) -> SimulationEnvelope raise WorkbenchError {
  let draft = load_draft(root, id, revision)
  require(
    draft.design_digest == expected_digest,
    "Draft changed or stale selection; re-open before building",
  )
  let build = revision_root(root, id, revision) + "/build"
  if @fsx.path_exists(build + "/package.json") {
    return export_input(root, id, revision, expected_digest)
  }
  require(
    !@fsx.path_exists(build),
    "Build outcome is unconfirmed; preserve this revision and use a new revision after review",
  )
  @fsx.create_dir(build) catch {
    _ => raise WorkbenchError("Build already reserved; re-open this revision")
  }
  let artifact = build + "/artifact"
  let ref = artifact_ref(id, revision)
  let design_ref = ref + "/design/robot-design.json"
  match
    @design_builder.build_robobook(
      draft.design_text,
      design_ref,
      artifact,
      draft.recorded_at,
      source_artifact_ref=design_ref,
    ) {
    Err(error) => raise WorkbenchError(error.field + ": " + error.message)
    Ok(_) => ()
  }
  let validation = match
    @design_builder.validate_robobook(artifact, draft.recorded_at) {
    Err(error) => raise WorkbenchError(error.field + ": " + error.message)
    Ok(value) => value
  }
  // Portable receipt paths: do not export a host-specific absolute root.
  let portable_validation = match validation {
    Object(fields) => {
      fields["root"] = ref.to_json()
      fields["receipt_path"] = (ref + "/design/validation-receipt.json").to_json()
      Json::object(fields)
    }
    _ => validation
  }
  let attempt = "workbench-" + id + "-" + revision
  let receipt : @suite_adapter.AdapterOperationReceipt = {
    contract_id: "moonrobo.digital-model-integration-receipt.v1",
    adapter_id: @suite_adapter.adapter_id(),
    operation_id: "robot.integrate-digital-model",
    operation_version: "1.0.0",
    request_id: attempt,
    attempt_id: attempt,
    idempotency_key: attempt,
    status: "succeeded",
    authority_class: "workspace-mutation",
    physical_execution_performed: false,
    input_digest: draft.design_digest,
    observed_input_digests: [draft.design_digest],
    evidence_refs: [
      ref + "/design/build-receipt.json",
      ref + "/design/validation-receipt.json",
      ref + "/model/robot.urdf",
      ref + "/robot.json",
    ],
    output_contract: "moonrobo.digital-model-integration-receipt.v1",
    output: {
      "accepted": true,
      "robobook_ref": ref,
      "build_receipt_ref": ref + "/design/build-receipt.json",
      "validation_receipt_ref": ref + "/design/validation-receipt.json",
      "model_ref": ref + "/model/robot.urdf",
      "validation": portable_validation,
      "claim_ceiling": "digital-artifact",
      "physical_ready": false,
    },
    error_kind: "",
    message: "Built and validated a fresh digital-only workbench revision; no simulation or physical execution performed.",
    recorded_at: draft.recorded_at,
  }
  write(
    artifact + "/design/integration-receipt.json",
    receipt.to_json().stringify(indent=2) + "\n",
  )
  let sources = generated_files().map(file => {
    let text = read(artifact + "/" + file)
    {
      artifact_ref: ref + "/" + file,
      digest: @moondata_core.text_checksum(text),
      text,
    }
  })
  let packet : SimulationInput = {
    contract_id: "moonrobo.simulation-input.v1",
    design_id: id,
    revision,
    design_ref,
    integration_receipt_ref: ref + "/design/integration-receipt.json",
    robot_artifact: robot_binding(id, revision, sources),
    sources,
    review_required: true,
    physical_execution_allowed: false,
    limitations: [
      "Excavation-haul digital concept only. Generic box links and revolute joints are not general CAD, manufacturing geometry or calibrated dynamics.",
      "Validation checks artifact consistency, not execution of the declared mission scenarios.",
      "MoonMoon must supply site, terrain, mission criteria and calibration evidence before simulation. This robot-input package contains no simulation result or physical readiness claim.",
    ],
  }
  let package_json = packet.to_json().stringify(indent=2) + "\n"
  let envelope : SimulationEnvelope = {
    contract_id: "moonrobo.simulation-input-envelope.v1",
    package_digest: @moondata_core.text_checksum(package_json),
    package_json,
  }
  // Commit marker last. Any interrupted write remains explicitly unconfirmed.
  write(build + "/package.json", envelope.to_json().stringify(indent=2) + "\n")
  export_input(root, id, revision, expected_digest)
}

///|
pub fn inspect_revision(
  root : String,
  id : String,
  revision : String,
) -> Json raise WorkbenchError {
  let draft = load_draft(root, id, revision)
  let build = revision_root(root, id, revision) + "/build"
  if !@fsx.path_exists(build) {
    return {
      "draft": draft,
      "state": "draft",
      "package": Json::null(),
      "physical_execution_allowed": false,
    }
  }
  let packet = export_input(root, id, revision, draft.design_digest) catch {
    WorkbenchError(message) =>
      return {
        "draft": draft,
        "state": "unconfirmed",
        "package": Json::null(),
        "message": message,
        "physical_execution_allowed": false,
      }
  }
  {
    "draft": draft,
    "state": "built",
    "package": packet,
    "physical_execution_allowed": false,
  }
}
