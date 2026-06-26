///|
pub(all) struct CockpitRobotSummary {
  root : String
  robot_id : @core.RobotId
  label : String
  platform : String
  model_primary : String
  ready : Bool
  missing_paths : Int
  validation_issues : Int
  joints : Int
  sensors : Int
  capabilities : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct CockpitBridgeSummary {
  bridge_id : @core.BridgeId
  status : String
  mode : String
  telemetry_age_ms : Int?
  telemetry_stale : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct CockpitSidecarSummary {
  sidecar_id : String
  state : String
  command_path : String
  command_available : Bool
  health_path : String
  execute_path : String
  ready_for_execution : Bool
  detail : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct CockpitTelemetrySummary {
  frame_id : String
  captured_at_ms : Int64
  mode : String
  joints : Int
  imu_available : Bool
  operator_input_fields : Int
  errors : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct CockpitViewportJoint {
  name : String
  index : Int
  role : String
  side : String
  mapped : Bool
  model_mapped : Bool
  model_joint_type : String
  parent_link : String
  child_link : String
  limit_lower : Double?
  limit_upper : Double?
  limit_state : String
  normalized_position : Double?
  position : Double
  velocity : Double
  torque : Double
  error : String?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct CockpitViewportVisual {
  index : Int
  link_name : String
  geometry_kind : String
  mesh_filename : String
  mesh_scale : String
  size : String
  radius : Double?
  length : Double?
  origin : @urdf.UrdfOrigin
  resolved_mesh_path : String
  asset_status : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct CockpitModelViewport {
  source_path : String
  resolved_path : String
  format : String
  renderer : String
  status : String
  root_link : String
  declared_joints : Int
  telemetry_joints : Int
  model_links : Int
  model_joints : Int
  visual_geometries : Int
  mesh_geometries : Int
  primitive_geometries : Int
  resolved_meshes : Int
  missing_meshes : Int
  external_meshes : Int
  simulated_links : Int
  mapped_joints : Int
  unmapped_joints : Int
  model_mapped_joints : Int
  model_unmapped_joints : Int
  extra_model_joints : Int
  extra_telemetry_joints : Int
  issue_count : Int
  issues : Array[String]
  links : Array[@urdf_viewport.ViewportLinkPose]
  visuals : Array[CockpitViewportVisual]
  visual_instances : Array[@urdf_viewport.ViewportVisualInstance]
  joints : Array[CockpitViewportJoint]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct CockpitSafetySummary {
  intent_id : @core.IntentId
  capability : @core.CapabilityId
  decision : String
  reason : String
  next_action : String
  detail : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct CockpitReceiptSummary {
  receipt_id : @core.ReceiptId
  status : String
  capability : @core.CapabilityId
  started_at_ms : Int64
  bridge_error : String?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct CockpitSnapshot {
  robot : CockpitRobotSummary
  product_status : @product_status.MoonroboProductStatus
  bridge : CockpitBridgeSummary
  sidecar : CockpitSidecarSummary
  telemetry : CockpitTelemetrySummary
  model_viewport : CockpitModelViewport
  safety : CockpitSafetySummary
  receipt_count : Int
  latest_receipt : CockpitReceiptSummary?
  read_only : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn initial_product_status(
  book : @runtime.LoadedRoboBook,
) -> @product_status.MoonroboProductStatus {
  @product_status.project({
    root: book.root,
    robot_id: book.profile.id,
    bridge_id: book.profile.bridge.id,
    mapped: book.status.ready,
    has_task_message: false,
    memory_card_count: 0,
    can_submit_gateway_command: false,
    physical_execution_allowed: false,
    loop_ready: false,
    loop_percent: 0,
    loop_status: "incomplete",
    live_readiness_status: "needs-runtime-validation",
    latest_task_execution_path: "",
    latest_gateway_command_path: "",
    latest_robo_loop_path: "",
    latest_proof_session_path: "",
    proof_session_feedback_closed: false,
    proof_session_auto_feedback_success_count: 0,
    proof_session_latest_feedback_status: 0,
    proof_session_latest_feedback_message: "",
    next_route: "/api/moonrobo/readiness",
  })
}

///|
pub fn next_action_text(action : @pipeline.PipelineNextAction) -> String {
  match action {
    Execute => "execute"
    CollectDryRun => "collect-dry-run"
    RequestApproval => "request-approval"
    Stop => "stop"
  }
}

///|
pub fn run_status_text(status : @core.RunStatus) -> String {
  match status {
    Denied => "denied"
    WaitingForApproval => "waiting-for-approval"
    WaitingForDryRun => "waiting-for-dry-run"
    ReadyForExecution => "ready-for-execution"
    Executed => "executed"
    Failed => "failed"
  }
}

///|
pub fn safety_decision_text(decision : @core.SafetyDecision) -> String {
  match decision {
    Allow => "allow"
    Deny => "deny"
    ApprovalRequired => "approval-required"
    DryRunRequired => "dry-run-required"
  }
}

///|
pub fn safety_reason_text(reason : @core.SafetyReason) -> String {
  match reason {
    Safe => "safe"
    RobotMismatch => "robot-mismatch"
    BridgeUnavailable => "bridge-unavailable"
    UnsupportedCapability => "unsupported-capability"
    DisabledCapability => "disabled-capability"
    StaleTelemetry => "stale-telemetry"
    ApprovalMissing => "approval-missing"
    DryRunMissing => "dry-run-missing"
    DeveloperGateRequired => "developer-gate-required"
    InvalidParameter => "invalid-parameter"
    MotionLimitExceeded => "motion-limit-exceeded"
  }
}

///|
pub fn robot_summary(book : @runtime.LoadedRoboBook) -> CockpitRobotSummary {
  {
    root: book.root,
    robot_id: book.profile.id,
    label: book.profile.label,
    platform: book.profile.platform,
    model_primary: book.profile.model.primary,
    ready: book.status.ready,
    missing_paths: book.status.missing_paths.length(),
    validation_issues: book.status.profile_report.issues.length(),
    joints: book.profile.joints.length(),
    sensors: book.profile.sensors.length(),
    capabilities: book.profile.capabilities.length(),
  }
}

///|
pub fn bridge_summary(
  profile : @core.RobotProfile,
  health : @core.BridgeHealth,
) -> CockpitBridgeSummary {
  let stale = match health.last_telemetry_age_ms {
    None => true
    Some(age) => age > profile.limits.telemetry_freshness_ms
  }
  {
    bridge_id: health.bridge_id,
    status: health.status,
    mode: health.mode,
    telemetry_age_ms: health.last_telemetry_age_ms,
    telemetry_stale: stale,
  }
}

///|
pub fn sidecar_state_text(state : @bridge_sidecar.SidecarState) -> String {
  match state {
    MissingCommand => "missing-command"
    Launchable => "launchable"
  }
}

///|
pub fn sidecar_summary(
  status : @bridge_sidecar.BridgeSidecarStatus,
) -> CockpitSidecarSummary {
  {
    sidecar_id: status.sidecar_id,
    state: sidecar_state_text(status.state),
    command_path: status.command_path,
    command_available: status.command_available,
    health_path: status.health_path,
    execute_path: status.execute_path,
    ready_for_execution: status.ready_for_execution,
    detail: status.detail,
  }
}

///|
pub fn telemetry_summary(
  telemetry : @core.TelemetryFrame,
) -> CockpitTelemetrySummary {
  {
    frame_id: telemetry.frame_id,
    captured_at_ms: telemetry.captured_at_ms,
    mode: telemetry.mode,
    joints: telemetry.joints.length(),
    imu_available: telemetry.imu is Some(_),
    operator_input_fields: telemetry.operator_input.length(),
    errors: telemetry.errors.length(),
  }
}

///|
pub fn model_format(path : String) -> String {
  if path.has_suffix(".urdf") {
    "urdf"
  } else if path.has_suffix(".mjcf") {
    "mjcf"
  } else if path.has_suffix(".usd") {
    "usd"
  } else if path == "" {
    "missing"
  } else {
    "unknown"
  }
}

///|
fn model_dir(path : String) -> String {
  let mut result = ""
  let mut pending = ""
  let mut seen = false
  for piece in path.split("/") {
    if seen {
      if result != "" {
        result += "/"
      }
      result += pending
    }
    pending = piece.to_owned()
    seen = true
  }
  result
}

///|
fn join_relative_path(prefix : String, child : String) -> String {
  if prefix == "" {
    child
  } else if child == "" {
    prefix
  } else {
    "\{prefix}/\{child}"
  }
}

///|
fn is_external_mesh(filename : String) -> Bool {
  filename.has_prefix("package://") ||
  filename.has_prefix("http://") ||
  filename.has_prefix("https://")
}

///|
fn resolved_mesh_path(
  root : String,
  model_path : String,
  mesh_filename : String,
) -> String {
  if mesh_filename == "" || is_external_mesh(mesh_filename) {
    ""
  } else if mesh_filename.has_prefix("/") {
    mesh_filename
  } else {
    @runtime.robobook_path(
      root,
      join_relative_path(model_dir(model_path), mesh_filename),
    )
  }
}

///|
fn visual_asset_status(
  root : String,
  model_path : String,
  visual : @urdf.UrdfVisual,
) -> String {
  if visual.geometry_kind != "mesh" {
    "primitive"
  } else if is_external_mesh(visual.mesh_filename) {
    "external"
  } else {
    let path = resolved_mesh_path(root, model_path, visual.mesh_filename)
    if path != "" && @fsx.path_exists(path) {
      "resolved"
    } else {
      "missing"
    }
  }
}

///|
fn viewport_visuals(
  root : String,
  model_path : String,
  model : @urdf.UrdfModel?,
) -> Array[CockpitViewportVisual] {
  match model {
    Some(value) => {
      let result : Array[CockpitViewportVisual] = []
      for index in 0..<value.visuals.length() {
        let visual = value.visuals[index]
        result.push({
          index,
          link_name: visual.link_name,
          geometry_kind: visual.geometry_kind,
          mesh_filename: visual.mesh_filename,
          mesh_scale: visual.mesh_scale,
          size: visual.size,
          radius: visual.radius,
          length: visual.length,
          origin: visual.origin,
          resolved_mesh_path: resolved_mesh_path(
            root,
            model_path,
            visual.mesh_filename,
          ),
          asset_status: visual_asset_status(root, model_path, visual),
        })
      }
      result
    }
    None => []
  }
}

///|
fn mesh_geometry_count(model : @urdf.UrdfModel?) -> Int {
  match model {
    Some(value) =>
      value.visuals
      .filter(fn(visual) { visual.geometry_kind == "mesh" })
      .length()
    None => 0
  }
}

///|
fn primitive_geometry_count(model : @urdf.UrdfModel?) -> Int {
  match model {
    Some(value) =>
      value.visuals
      .filter(fn(visual) { visual.geometry_kind != "mesh" })
      .length()
    None => 0
  }
}

///|
fn external_mesh_count(model : @urdf.UrdfModel?) -> Int {
  match model {
    Some(value) =>
      value.visuals
      .filter(fn(visual) {
        visual.geometry_kind == "mesh" && is_external_mesh(visual.mesh_filename)
      })
      .length()
    None => 0
  }
}

///|
fn resolved_mesh_count(
  root : String,
  model_path : String,
  model : @urdf.UrdfModel?,
) -> Int {
  match model {
    Some(value) => {
      let mut count = 0
      for visual in value.visuals {
        if visual.geometry_kind == "mesh" {
          let path = resolved_mesh_path(root, model_path, visual.mesh_filename)
          if path != "" && @fsx.path_exists(path) {
            count += 1
          }
        }
      }
      count
    }
    None => 0
  }
}

///|
fn missing_mesh_count(
  root : String,
  model_path : String,
  model : @urdf.UrdfModel?,
) -> Int {
  match model {
    Some(value) => {
      let mut count = 0
      for visual in value.visuals {
        if visual.geometry_kind == "mesh" &&
          !is_external_mesh(visual.mesh_filename) {
          let path = resolved_mesh_path(root, model_path, visual.mesh_filename)
          if path == "" || !@fsx.path_exists(path) {
            count += 1
          }
        }
      }
      count
    }
    None => 0
  }
}

///|
fn joint_role(name : String) -> String {
  if name.contains("arm") {
    "arm"
  } else if name.contains("leg") {
    "leg"
  } else if name.contains("waist") {
    "torso"
  } else {
    "joint"
  }
}

///|
fn joint_side(name : String) -> String {
  if name.contains("_l") {
    "left"
  } else if name.contains("_r") {
    "right"
  } else {
    "center"
  }
}

///|
fn telemetry_matches_spec(
  telemetry : @core.JointTelemetry,
  spec : @core.JointSpec,
) -> Bool {
  telemetry.name == spec.name || telemetry.index == spec.index
}

///|
fn telemetry_for_joint(
  telemetry : @core.TelemetryFrame,
  spec : @core.JointSpec,
) -> @core.JointTelemetry? {
  for joint in telemetry.joints {
    if telemetry_matches_spec(joint, spec) {
      return Some(joint)
    }
  }
  None
}

///|
fn profile_has_telemetry_joint(
  profile : @core.RobotProfile,
  telemetry : @core.JointTelemetry,
) -> Bool {
  for spec in profile.joints {
    if telemetry_matches_spec(telemetry, spec) {
      return true
    }
  }
  false
}

///|
fn extra_telemetry_joint_count(
  profile : @core.RobotProfile,
  telemetry : @core.TelemetryFrame,
) -> Int {
  let mut count = 0
  for joint in telemetry.joints {
    if !profile_has_telemetry_joint(profile, joint) {
      count += 1
    }
  }
  count
}

///|
fn profile_has_model_joint(
  profile : @core.RobotProfile,
  joint : @urdf.UrdfJoint,
) -> Bool {
  for spec in profile.joints {
    if spec.name == joint.name {
      return true
    }
  }
  false
}

///|
fn extra_model_joint_count(
  profile : @core.RobotProfile,
  model : @urdf.UrdfModel?,
) -> Int {
  match model {
    None => 0
    Some(value) => {
      let mut count = 0
      for joint in value.joints {
        if !profile_has_model_joint(profile, joint) {
          count += 1
        }
      }
      count
    }
  }
}

///|
fn viewport_joint(
  spec : @core.JointSpec,
  telemetry : @core.TelemetryFrame,
  model : @urdf.UrdfModel?,
) -> CockpitViewportJoint {
  let model_joint = match model {
    Some(value) => @urdf.find_joint(value, spec.name)
    None => None
  }
  let model_mapped = model_joint is Some(_)
  let model_joint_type = match model_joint {
    Some(value) => value.joint_type
    None => ""
  }
  let parent_link = match model_joint {
    Some(value) => value.parent_link
    None => ""
  }
  let child_link = match model_joint {
    Some(value) => value.child_link
    None => ""
  }
  let lower = @urdf_viewport.model_limit_lower(model_joint)
  let upper = @urdf_viewport.model_limit_upper(model_joint)
  match telemetry_for_joint(telemetry, spec) {
    Some(joint) =>
      {
        name: spec.name,
        index: spec.index,
        role: joint_role(spec.name),
        side: joint_side(spec.name),
        mapped: true,
        model_mapped,
        model_joint_type,
        parent_link,
        child_link,
        limit_lower: lower,
        limit_upper: upper,
        limit_state: @urdf_viewport.limit_state(
          true,
          model_mapped,
          joint.position,
          lower,
          upper,
        ),
        normalized_position: @urdf_viewport.normalized_position(
          joint.position,
          lower,
          upper,
        ),
        position: joint.position,
        velocity: joint.velocity,
        torque: joint.torque,
        error: joint.error,
      }
    None =>
      {
        name: spec.name,
        index: spec.index,
        role: joint_role(spec.name),
        side: joint_side(spec.name),
        mapped: false,
        model_mapped,
        model_joint_type,
        parent_link,
        child_link,
        limit_lower: lower,
        limit_upper: upper,
        limit_state: @urdf_viewport.limit_state(
          false, model_mapped, 0.0, lower, upper,
        ),
        normalized_position: None,
        position: 0.0,
        velocity: 0.0,
        torque: 0.0,
        error: Some("missing-telemetry"),
      }
  }
}

///|
pub fn model_viewport(
  book : @runtime.LoadedRoboBook,
  telemetry : @core.TelemetryFrame,
  urdf_model? : @urdf.UrdfModel? = None,
) -> CockpitModelViewport {
  let source_path = book.profile.model.primary
  let format = model_format(source_path)
  let resolved_path = @runtime.robobook_path(book.root, source_path)
  let issues : Array[String] = []
  if source_path == "" {
    issues.push("model.primary is empty")
  } else if book.status.missing_paths.contains(source_path) {
    issues.push("model artifact is missing: \{source_path}")
  }
  if format != "urdf" {
    issues.push(
      "first cockpit viewport supports URDF as the canonical MVP format",
    )
  }
  let model_links = match urdf_model {
    Some(value) => value.link_count
    None => 0
  }
  let model_joints = match urdf_model {
    Some(value) => value.joint_count
    None => 0
  }
  let visual_geometries = match urdf_model {
    Some(value) => value.visual_count
    None => 0
  }
  let mesh_geometries = mesh_geometry_count(urdf_model)
  let primitive_geometries = primitive_geometry_count(urdf_model)
  let resolved_meshes = resolved_mesh_count(book.root, source_path, urdf_model)
  let missing_meshes = missing_mesh_count(book.root, source_path, urdf_model)
  let external_meshes = external_mesh_count(urdf_model)
  match urdf_model {
    Some(value) =>
      for issue in value.issues {
        issues.push("URDF parse: \{issue}")
      }
    None =>
      if source_path != "" && !book.status.missing_paths.contains(source_path) {
        issues.push("URDF model was not parsed for viewport")
      }
  }
  let joints = book.profile.joints.map(fn(spec) {
    viewport_joint(spec, telemetry, urdf_model)
  })
  let visuals = viewport_visuals(book.root, source_path, urdf_model)
  let simulation = @urdf_viewport.simulate(urdf_model, telemetry)
  let visual_instances = @urdf_viewport.visual_instances(urdf_model, telemetry)
  let mapped_joints = joints.filter(fn(joint) { joint.mapped }).length()
  let model_mapped_joints = joints
    .filter(fn(joint) { joint.model_mapped })
    .length()
  let model_unmapped_joints = joints.length() - model_mapped_joints
  let extra_model_joints = extra_model_joint_count(book.profile, urdf_model)
  if model_unmapped_joints > 0 {
    issues.push(
      "\{model_unmapped_joints} RoboBook joint(s) are missing from URDF",
    )
  }
  if extra_model_joints > 0 {
    issues.push(
      "URDF includes \{extra_model_joints} joint(s) outside the RoboBook map",
    )
  }
  let extra_telemetry_joints = extra_telemetry_joint_count(
    book.profile,
    telemetry,
  )
  if extra_telemetry_joints > 0 {
    issues.push(
      "telemetry includes \{extra_telemetry_joints} joint(s) outside the RoboBook map",
    )
  }
  let limit_violation_count = joints
    .filter(fn(joint) {
      joint.limit_state == "below-limit" || joint.limit_state == "above-limit"
    })
    .length()
  if limit_violation_count > 0 {
    issues.push("\{limit_violation_count} joint pose(s) exceed URDF limits")
  }
  if missing_meshes > 0 {
    issues.push("\{missing_meshes} URDF mesh asset(s) are missing")
  }
  let unmapped_joints = joints.length() - mapped_joints
  if unmapped_joints > 0 {
    issues.push(
      "\{unmapped_joints} declared joint(s) have no telemetry mapping",
    )
  }
  {
    source_path,
    resolved_path,
    format,
    renderer: "three-stl",
    status: if issues.is_empty() {
      "ready"
    } else {
      "diagnostic"
    },
    root_link: simulation.root_link,
    declared_joints: book.profile.joints.length(),
    telemetry_joints: telemetry.joints.length(),
    model_links,
    model_joints,
    visual_geometries,
    mesh_geometries,
    primitive_geometries,
    resolved_meshes,
    missing_meshes,
    external_meshes,
    simulated_links: simulation.simulated_links,
    mapped_joints,
    unmapped_joints,
    model_mapped_joints,
    model_unmapped_joints,
    extra_model_joints,
    extra_telemetry_joints,
    issue_count: issues.length(),
    issues,
    links: simulation.links,
    visuals,
    visual_instances,
    joints,
  }
}

///|
pub fn safety_summary(
  result : @pipeline.PipelineResult,
) -> CockpitSafetySummary {
  {
    intent_id: result.intent.intent_id,
    capability: result.intent.capability,
    decision: safety_decision_text(result.verdict.decision),
    reason: safety_reason_text(result.verdict.reason),
    next_action: next_action_text(result.next_action),
    detail: result.verdict.detail,
  }
}

///|
pub fn receipt_summary(receipt : @core.RunReceipt) -> CockpitReceiptSummary {
  {
    receipt_id: receipt.receipt_id,
    status: run_status_text(receipt.status),
    capability: receipt.intent.capability,
    started_at_ms: receipt.started_at_ms,
    bridge_error: receipt.bridge_error,
  }
}

///|
pub fn latest_receipt(
  receipts : Array[@core.RunReceipt],
) -> CockpitReceiptSummary? {
  if receipts.is_empty() {
    None
  } else {
    Some(receipt_summary(receipts[receipts.length() - 1]))
  }
}

///|
pub fn snapshot(
  book : @runtime.LoadedRoboBook,
  health : @core.BridgeHealth,
  sidecar : @bridge_sidecar.BridgeSidecarStatus,
  telemetry : @core.TelemetryFrame,
  safety : @pipeline.PipelineResult,
  receipts : Array[@core.RunReceipt],
  product_status? : @product_status.MoonroboProductStatus = initial_product_status(
    book,
  ),
  urdf_model? : @urdf.UrdfModel? = None,
) -> CockpitSnapshot {
  {
    robot: robot_summary(book),
    product_status,
    bridge: bridge_summary(book.profile, health),
    sidecar: sidecar_summary(sidecar),
    telemetry: telemetry_summary(telemetry),
    model_viewport: model_viewport(book, telemetry, urdf_model~),
    safety: safety_summary(safety),
    receipt_count: receipts.length(),
    latest_receipt: latest_receipt(receipts),
    read_only: safety.next_action != Execute,
  }
}

///|
pub fn snapshot_json(snapshot : CockpitSnapshot, indent? : Int = 2) -> String {
  snapshot.to_json().stringify(indent~)
}
