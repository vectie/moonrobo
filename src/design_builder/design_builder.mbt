///|
pub(all) struct DesignBuildIssue {
  code : String
  field : String
  message : String
} derive(Debug, Eq, ToJson)

///|
pub(all) struct DesignBuildResult {
  design_id : String
  revision : String
  root : String
  profile : @core.RobotProfile
  generated_paths : Array[String]
  receipt_path : String
} derive(Debug, Eq, ToJson)

///|
fn issue(code : String, field : String, message : String) -> DesignBuildIssue {
  { code, field, message }
}

///|
fn object_field(value : Json, name : String) -> Map[String, Json]? {
  match value {
    Object(fields) =>
      match fields.get(name) {
        Some(Object(value)) => Some(value)
        _ => None
      }
    _ => None
  }
}

///|
fn string_field(value : Json, name : String) -> String? {
  match value {
    Object(fields) =>
      match fields.get(name) {
        Some(String(value)) => Some(value)
        _ => None
      }
    _ => None
  }
}

///|
fn number_field(fields : Map[String, Json], name : String) -> Double? {
  match fields.get(name) {
    Some(Number(value, ..)) => Some(value)
    _ => None
  }
}

///|
fn safe_design_id(value : String) -> Bool {
  if value.is_empty() {
    return false
  }
  for char in value {
    if !(char >= 'a' && char <= 'z') &&
      !(char >= '0' && char <= '9') &&
      char != '-' &&
      char != '_' {
      return false
    }
  }
  true
}

///|
pub fn profile_from_design(
  design : Json,
) -> Result[@core.RobotProfile, DesignBuildIssue] {
  let contract = string_field(design, "contract_id").unwrap_or("")
  if contract != "moonsuite.robot-design.v1" {
    return Err(
      issue(
        "unsupported-contract", "contract_id", "expected moonsuite.robot-design.v1",
      ),
    )
  }
  let design_id = string_field(design, "design_id").unwrap_or("")
  if !safe_design_id(design_id) {
    return Err(
      issue(
        "invalid-design-id", "design_id", "design id must be a non-empty lowercase slug",
      ),
    )
  }
  let revision = string_field(design, "revision").unwrap_or("")
  if revision.is_empty() {
    return Err(issue("missing-field", "revision", "revision is required"))
  }
  let mission = match object_field(design, "mission") {
    Some(value) => value
    None => return Err(issue("missing-field", "mission", "mission is required"))
  }
  let authority = match mission.get("authority") {
    Some(String(value)) => value
    _ => ""
  }
  if authority != "digital-only" {
    return Err(
      issue(
        "unsafe-authority", "mission.authority", "MoonRobo design builder accepts digital-only designs",
      ),
    )
  }
  let label = match mission.get("name") {
    Some(String(value)) if !value.is_empty() => value
    _ => design_id
  }
  let constraints = match object_field(design, "constraints") {
    Some(value) => value
    None =>
      return Err(
        issue("missing-field", "constraints", "constraints are required"),
      )
  }
  let speed = match constraints.get("commanded_speed_mps") {
    Some(Object(value)) => value
    _ =>
      return Err(
        issue(
          "missing-field", "constraints.commanded_speed_mps", "commanded speed range is required",
        ),
      )
  }
  let max_speed = number_field(speed, "max").unwrap_or(0.0)
  if max_speed <= 0.0 {
    return Err(
      issue(
        "invalid-limit", "constraints.commanded_speed_mps.max", "maximum commanded speed must be positive",
      ),
    )
  }
  let wheel_names = [
    "front_left_wheel_joint", "front_right_wheel_joint", "rear_left_wheel_joint",
    "rear_right_wheel_joint",
  ]
  let profile : @core.RobotProfile = {
    id: design_id,
    label,
    kind: MobileBase,
    platform: "moonsuite-lunar-rover-sim",
    profile_version: 1,
    model: { primary: "model/robot.urdf", alternates: [] },
    bridge: {
      id: "sim-\{design_id}",
      kind: Sim,
      config_path: "bridge/bridge.json",
    },
    joints: wheel_names.mapi((index, name) => @core.joint(name, index)),
    sensors: [
      @core.sensor("imu", "imu", "Chassis IMU"),
      @core.sensor("wheel-odometry", "odometry", "Wheel odometry"),
      @core.sensor("hazard-camera", "camera", "Forward hazard camera"),
    ],
    capabilities: [
      @core.capability("observe.telemetry", Observe, "Observe telemetry"),
      @core.capability("observe.joints", Observe, "Observe wheel state"),
      @core.capability("simulate.motion", Simulate, "Simulate bounded motion"),
      @core.capability(
        "control.emergency.stop",
        HighControl,
        "Emergency stop or hold",
      ),
      @core.capability(
        "control.high.drive",
        HighControl,
        "Physical drive disabled for digital design",
        enabled=false,
        requires_approval=true,
        requires_dry_run=true,
      ),
    ],
    limits: {
      telemetry_freshness_ms: 1000,
      heartbeat_ms: 500,
      default_mode: "simulation-only",
      high_control_max_x_abs: max_speed,
      high_control_max_yaw_abs: 0.25,
      high_control_max_duration_ms: 10000,
    },
  }
  let report = @core.validate_robot_profile(profile)
  if !report.valid {
    return Err(
      issue(
        "invalid-profile", "robot.json", "generated profile failed MoonRobo validation",
      ),
    )
  }
  Ok(profile)
}

///|
pub fn rover_urdf(design_id : String) -> String {
  let body =
    #|  <link name="chassis">
    #|    <visual><geometry><box size="0.90 0.65 0.25"/></geometry></visual>
    #|    <collision><geometry><box size="0.90 0.65 0.25"/></geometry></collision>
    #|  </link>
    #|  <link name="cargo_bay">
    #|    <visual><origin xyz="0 0 0.24"/><geometry><box size="0.48 0.42 0.22"/></geometry></visual>
    #|  </link>
    #|  <joint name="cargo_bay_fixed" type="fixed"><parent link="chassis"/><child link="cargo_bay"/><origin xyz="0 0 0.13"/></joint>
    #|  <link name="front_left_wheel"><visual><geometry><cylinder radius="0.18" length="0.10"/></geometry></visual></link>
    #|  <link name="front_right_wheel"><visual><geometry><cylinder radius="0.18" length="0.10"/></geometry></visual></link>
    #|  <link name="rear_left_wheel"><visual><geometry><cylinder radius="0.18" length="0.10"/></geometry></visual></link>
    #|  <link name="rear_right_wheel"><visual><geometry><cylinder radius="0.18" length="0.10"/></geometry></visual></link>
    #|  <joint name="front_left_wheel_joint" type="continuous"><parent link="chassis"/><child link="front_left_wheel"/><origin xyz="0.32 0.38 -0.08"/><axis xyz="0 1 0"/></joint>
    #|  <joint name="front_right_wheel_joint" type="continuous"><parent link="chassis"/><child link="front_right_wheel"/><origin xyz="0.32 -0.38 -0.08"/><axis xyz="0 1 0"/></joint>
    #|  <joint name="rear_left_wheel_joint" type="continuous"><parent link="chassis"/><child link="rear_left_wheel"/><origin xyz="-0.32 0.38 -0.08"/><axis xyz="0 1 0"/></joint>
    #|  <joint name="rear_right_wheel_joint" type="continuous"><parent link="chassis"/><child link="rear_right_wheel"/><origin xyz="-0.32 -0.38 -0.08"/><axis xyz="0 1 0"/></joint>
    #|</robot>
  "<?xml version=\"1.0\"?>\n<robot name=\"" + design_id + "\">\n" + body
}

///|
fn ensure_dir(path : String) -> Result[Unit, DesignBuildIssue] {
  if @fsx.path_exists(path) {
    return Ok(())
  }
  @fsx.create_dir(path) catch {
    _ => return Err(issue("create-dir", path, "failed to create directory"))
  }
  Ok(())
}

///|
fn ensure_directory_tree(path : String) -> Result[Unit, DesignBuildIssue] {
  let absolute = path.has_prefix("/")
  let mut current = if absolute { "" } else { "." }
  for component in path.split("/") {
    if component == "" || component == "." {
      continue
    }
    let component = component.to_owned()
    current = if current == "" || current == "/" {
      "/" + component
    } else {
      current + "/" + component
    }
    match ensure_dir(current) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  Ok(())
}

///|
fn write_file(path : String, text : String) -> Result[Unit, DesignBuildIssue] {
  @fsx.write_string_to_file(path, text) catch {
    _ => return Err(issue("write-file", path, "failed to write file"))
  }
  Ok(())
}

///|
pub fn build_robobook(
  design_text : String,
  source_path : String,
  root : String,
) -> Result[DesignBuildResult, DesignBuildIssue] {
  let design = @json.parse(design_text) catch {
    _ =>
      return Err(
        issue("parse-design", source_path, "failed to parse robot design JSON"),
      )
  }
  let profile = match profile_from_design(design) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let revision = string_field(design, "revision").unwrap_or("")
  match ensure_directory_tree(root) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match @runtime.ensure_process_dirs(root) {
    Ok(_) => ()
    Err(error) => return Err(issue(error.code, error.path, error.message))
  }
  for relative in ["model", "bridge", "safety", "design"] {
    match ensure_dir(root + "/" + relative) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  let generated_paths = [
    "robot.json", "model/robot.urdf", "bridge/bridge.json", "safety/policy.json",
    "design/robot-design.json", "design/build-receipt.json",
  ]
  let bridge : Json = {
    "bridge_id": profile.bridge.id,
    "kind": "Sim",
    "label": "MoonRobo deterministic simulation bridge",
    "protocol_version": 1,
    "mode": "simulation-only",
    "physical_transport_enabled": false,
    "design_id": profile.id,
    "design_revision": revision,
  }
  let safety : Json = {
    "policy_version": 1,
    "default_decision": "deny",
    "authority": "digital-only",
    "capabilities": {
      "observe.telemetry": { "decision": "allow" },
      "observe.joints": { "decision": "allow" },
      "simulate.motion": { "decision": "allow" },
      "control.emergency.stop": { "decision": "allow" },
      "control.high.drive": {
        "decision": "deny",
        "reason": "physical drive is outside this digital design authority",
      },
      "control.low.joint-position": { "decision": "deny" },
    },
  }
  let receipt : Json = {
    "contract_id": "moonsuite.run-receipt.v1",
    "run_id": "moonrobo-build-\{profile.id}-\{revision}",
    "stage_id": "moonrobo-build-design",
    "product_id": "moonrobo",
    "book_id": profile.id,
    "status": "accepted",
    "inputs": [source_path],
    "outputs": generated_paths,
    "quality": {
      "profile_valid": true,
      "digital_only": true,
      "physical_transport_enabled": false,
      "joint_count": profile.joints.length(),
    },
    "trials": 1,
    "started_at": revision,
    "finished_at": revision,
  }
  let writes : Array[(String, String)] = [
    ("robot.json", profile.to_json().stringify(indent=2) + "\n"),
    ("model/robot.urdf", rover_urdf(profile.id)),
    ("bridge/bridge.json", bridge.stringify(indent=2) + "\n"),
    ("safety/policy.json", safety.stringify(indent=2) + "\n"),
    ("design/robot-design.json", design.stringify(indent=2) + "\n"),
    ("design/build-receipt.json", receipt.stringify(indent=2) + "\n"),
  ]
  for item in writes {
    let (relative, text) = item
    match write_file(root + "/" + relative, text) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  Ok({
    design_id: profile.id,
    revision,
    root,
    profile,
    generated_paths,
    receipt_path: root + "/design/build-receipt.json",
  })
}

///|
pub fn validate_robobook(root : String) -> Result[Json, DesignBuildIssue] {
  let loaded = match @runtime.load_robobook(root) {
    Ok(value) => value
    Err(error) => return Err(issue(error.code, error.path, error.message))
  }
  if !loaded.status.ready {
    return Err(
      issue(
        "robobook-not-ready", root, "RoboBook required paths or profile validation are incomplete",
      ),
    )
  }
  let design_path = root + "/design/robot-design.json"
  let design_text = @fsx.read_file_to_string(design_path) catch {
    _ =>
      return Err(
        issue("read-design", design_path, "failed to read persisted design"),
      )
  }
  let design = @json.parse(design_text) catch {
    _ =>
      return Err(
        issue("parse-design", design_path, "failed to parse persisted design"),
      )
  }
  let expected = match profile_from_design(design) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if loaded.profile != expected {
    return Err(
      issue(
        "profile-drift", "robot.json", "persisted profile does not match the typed robot design",
      ),
    )
  }
  let urdf_path = root + "/" + loaded.profile.model.primary
  let urdf = @fsx.read_file_to_string(urdf_path) catch {
    _ => return Err(issue("read-urdf", urdf_path, "failed to read URDF"))
  }
  if !urdf.contains("<robot name=\"\{loaded.profile.id}\">") {
    return Err(
      issue("urdf-identity", urdf_path, "URDF robot id does not match profile"),
    )
  }
  for joint in loaded.profile.joints {
    if !urdf.contains("name=\"\{joint.name}\"") {
      return Err(
        issue(
          "urdf-joint-missing",
          urdf_path,
          "URDF is missing profile joint \{joint.name}",
        ),
      )
    }
  }
  let bridge_path = root + "/" + loaded.profile.bridge.config_path
  let bridge_text = @fsx.read_file_to_string(bridge_path) catch {
    _ =>
      return Err(
        issue("read-bridge", bridge_path, "failed to read bridge config"),
      )
  }
  let bridge = @json.parse(bridge_text) catch {
    _ =>
      return Err(
        issue("parse-bridge", bridge_path, "failed to parse bridge config"),
      )
  }
  let bridge_safe = match bridge {
    {
      "mode": String("simulation-only"),
      "physical_transport_enabled": False,
      ..
    } => true
    _ => false
  }
  if !bridge_safe {
    return Err(
      issue(
        "unsafe-bridge", bridge_path, "generated bridge must remain simulation-only with physical transport disabled",
      ),
    )
  }
  let safety_path = root + "/safety/policy.json"
  let safety_text = @fsx.read_file_to_string(safety_path) catch {
    _ =>
      return Err(
        issue("read-safety", safety_path, "failed to read safety policy"),
      )
  }
  let safety = @json.parse(safety_text) catch {
    _ =>
      return Err(
        issue("parse-safety", safety_path, "failed to parse safety policy"),
      )
  }
  if string_field(safety, "authority").unwrap_or("") != "digital-only" {
    return Err(
      issue(
        "unsafe-policy", safety_path, "safety policy must preserve digital-only authority",
      ),
    )
  }
  let revision = string_field(design, "revision").unwrap_or("")
  let receipt_path = root + "/design/validation-receipt.json"
  let quality : Json = {
    "robobook_ready": true,
    "profile_matches_design": true,
    "urdf_identity_matches": true,
    "urdf_joint_count": loaded.profile.joints.length(),
    "simulation_only": true,
    "physical_transport_enabled": false,
    "digital_only": true,
  }
  let receipt : Json = {
    "contract_id": "moonsuite.run-receipt.v1",
    "run_id": "moonrobo-validate-\{loaded.profile.id}-\{revision}",
    "stage_id": "moonrobo-validate-design",
    "product_id": "moonrobo",
    "book_id": loaded.profile.id,
    "status": "accepted",
    "inputs": [
      "design/robot-design.json",
      "robot.json",
      loaded.profile.model.primary,
      loaded.profile.bridge.config_path,
      "safety/policy.json",
    ],
    "outputs": ["design/validation-receipt.json"],
    "quality": quality,
    "trials": 1,
    "started_at": revision,
    "finished_at": revision,
  }
  match write_file(receipt_path, receipt.stringify(indent=2) + "\n") {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  Ok({
    "accepted": true,
    "robot_id": loaded.profile.id,
    "revision": revision,
    "root": root,
    "joint_count": loaded.profile.joints.length(),
    "bridge_kind": "Sim",
    "receipt_path": receipt_path,
    "quality": quality,
  })
}
