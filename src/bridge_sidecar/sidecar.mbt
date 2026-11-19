///|
pub(all) enum SidecarTransport {
  LocalHttp
  Stdio
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SupervisionPolicy {
  Manual
  RestartOnFailure
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct BridgeSidecarSpec {
  sidecar_id : String
  bridge_id : @core.BridgeId
  robot_id : @core.RobotId
  kind : @core.BridgeKind
  protocol_version : Int32
  transport : SidecarTransport
  command : Array[String]
  env : Map[String, String]
  contract_path : String
  health_path : String
  telemetry_path : String
  execute_path : String
  mode : String
  supervision : SupervisionPolicy
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SidecarState {
  MissingCommand
  Launchable
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct BridgeSidecarStatus {
  sidecar_id : String
  bridge_id : @core.BridgeId
  robot_id : @core.RobotId
  state : SidecarState
  command_path : String
  command_available : Bool
  protocol_version : Int32
  contract_path : String
  health_path : String
  execute_path : String
  ready_for_execution : Bool
  detail : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum RuntimeProcessRole {
  SnapshotCollector
  HighControlWriter
  BridgeSidecar
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RuntimeProcessSpec {
  process_id : String
  role : RuntimeProcessRole
  command : Array[String]
  env : Map[String, String]
  cwd : String
  output_path : String
  health_path : String
  depends_on : Array[String]
  supervision : SupervisionPolicy
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PhysicalRuntimeSpec {
  runtime_id : String
  robot_id : @core.RobotId
  bridge_id : @core.BridgeId
  snapshot_path : String
  command_path : String
  bridge_base_url : String
  processes : Array[RuntimeProcessSpec]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn default_sdk_e1_sidecar_path() -> String {
  @env.get_env_var("MOONROBO_SDK_E1_BRIDGE").unwrap_or("moonrobo-sdk-e1-bridge")
}

///|
pub(all) enum SdkE1Backend {
  Native
  PythonReference
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn sdk_e1_backend(name : String) -> SdkE1Backend? {
  match name {
    "native" => Some(Native)
    "python-reference" => Some(PythonReference)
    _ => None
  }
}

///|
/// Reference execution is opt-in. Unknown settings retain the native default.
pub fn default_sdk_e1_backend() -> SdkE1Backend {
  sdk_e1_backend(
    @env.get_env_var("MOONROBO_SDK_E1_BACKEND").unwrap_or("native"),
  ).unwrap_or(Native)
}

///|
pub fn default_sdk_e1_native_path() -> String {
  @env.get_env_var("MOONROBO_SDK_E1_NATIVE").unwrap_or("moonrobo-sdk-e1-native")
}

///|
pub fn default_sdk_e1_collector_path() -> String {
  default_sdk_e1_native_path()
}

///|
pub fn default_sdk_e1_writer_path() -> String {
  default_sdk_e1_native_path()
}

///|
pub fn reference_sdk_e1_collector_path() -> String {
  "bridges/sdk_e1/sdk_e1_readonly_bridge.py"
}

///|
pub fn reference_sdk_e1_writer_path() -> String {
  "bridges/sdk_e1/sdk_e1_high_control_writer.py"
}

///|
pub fn default_python_path() -> String {
  @env.get_env_var("MOONROBO_SDK_E1_REFERENCE_PYTHON").unwrap_or("python3")
}

///|
pub fn default_sdk_root() -> String {
  @env.get_env_var("MOONROBO_SDK_E1_ROOT").unwrap_or("../sdk")
}

///|
pub fn default_sdk_e1_library_path(sdk_root : String) -> String {
  @env.get_env_var("MOONROBO_SDK_E1_LIBRARY").unwrap_or(
    sdk_root + "/build/libmoonrobo_e1.so",
  )
}

///|
fn sdk_environment(sdk_root : String) -> Map[String, String] {
  let absolute = if @pathx.is_absolute(sdk_root) {
    sdk_root
  } else {
    @pathx.join(@env.current_dir().unwrap_or("."), sdk_root)
  }
  {
    "CYCLONEDDS_URI": @env.get_env_var("CYCLONEDDS_URI").unwrap_or(
      "file://" + @pathx.normalize(@pathx.join(absolute, "config/dds.xml")),
    ),
  }
}

///|
fn active_workspace_root() -> String {
  "."
}

///|
pub fn default_snapshot_path_for_workspace_root(root : String) -> String {
  @pathx.join(
    @moonsuite.product_home_for_workspace_root(root, "moonrobo").tmp_path,
    "sdk-e1/snapshot.json",
  )
}

///|
pub fn default_snapshot_path() -> String {
  default_snapshot_path_for_workspace_root(active_workspace_root())
}

///|
pub fn default_command_path_for_workspace_root(root : String) -> String {
  @pathx.join(
    @moonsuite.product_home_for_workspace_root(root, "moonrobo").tmp_path,
    "sdk-e1/command.json",
  )
}

///|
pub fn default_command_path() -> String {
  default_command_path_for_workspace_root(active_workspace_root())
}

///|
pub fn default_bridge_host() -> String {
  "127.0.0.1"
}

///|
pub fn default_bridge_port() -> Int32 {
  5391
}

///|
pub fn sidecar_id(profile : @core.RobotProfile) -> String {
  "\{profile.id}:\{profile.bridge.id}"
}

///|
pub fn sdk_e1_command(
  robobook_root : String,
  sidecar_path~ : String = default_sdk_e1_sidecar_path(),
  host~ : String = default_bridge_host(),
  port~ : Int32 = default_bridge_port(),
  snapshot_path~ : String = default_snapshot_path(),
  command_path~ : String = default_command_path(),
  mode~ : String = "control-gated",
) -> Array[String] {
  [
    sidecar_path,
    "serve",
    robobook_root,
    host,
    port.to_string(),
    snapshot_path,
    mode,
    command_path,
  ]
}

///|
pub fn sdk_e1_collector_command(
  collector_path? : String,
  python_path~ : String = default_python_path(),
  backend~ : SdkE1Backend = default_sdk_e1_backend(),
  library_path? : String,
  sdk_root~ : String = default_sdk_root(),
  snapshot_path~ : String = default_snapshot_path(),
  interval_ms~ : Int32 = 100,
) -> Array[String] {
  let command = match backend {
    Native =>
      [collector_path.unwrap_or(default_sdk_e1_collector_path()), "read"]
    PythonReference =>
      [python_path, collector_path.unwrap_or(reference_sdk_e1_collector_path())]
  }
  command.append([
    "--live",
    "--sdk-root",
    sdk_root,
    "--output",
    snapshot_path,
    "--interval-ms",
    interval_ms.to_string(),
  ])
  if backend == Native {
    command.append([
      "--library",
      library_path.unwrap_or(default_sdk_e1_library_path(sdk_root)),
    ])
  }
  command
}

///|
pub fn sdk_e1_writer_command(
  writer_path? : String,
  python_path~ : String = default_python_path(),
  backend~ : SdkE1Backend = default_sdk_e1_backend(),
  library_path? : String,
  sdk_root~ : String = default_sdk_root(),
  command_path~ : String = default_command_path(),
  poll_ms~ : Int32 = 50,
  dry_run~ : Bool = false,
) -> Array[String] {
  let command = match backend {
    Native => [writer_path.unwrap_or(default_sdk_e1_writer_path()), "write"]
    PythonReference =>
      [python_path, writer_path.unwrap_or(reference_sdk_e1_writer_path())]
  }
  command.append([
    "--watch",
    "--input",
    command_path,
    "--sdk-root",
    sdk_root,
    "--poll-ms",
    poll_ms.to_string(),
  ])
  if backend == Native {
    command.append([
      "--library",
      library_path.unwrap_or(default_sdk_e1_library_path(sdk_root)),
    ])
  }
  if dry_run {
    command.push("--dry-run")
  }
  command
}

///|
pub fn spec_for_profile(
  profile : @core.RobotProfile,
  robobook_root : String,
  sidecar_path~ : String = default_sdk_e1_sidecar_path(),
  host~ : String = default_bridge_host(),
  port~ : Int32 = default_bridge_port(),
  snapshot_path~ : String = default_snapshot_path(),
  command_path~ : String = default_command_path(),
) -> BridgeSidecarSpec {
  {
    sidecar_id: sidecar_id(profile),
    bridge_id: profile.bridge.id,
    robot_id: profile.id,
    kind: profile.bridge.kind,
    protocol_version: @bridge_protocol.protocol_version(),
    transport: LocalHttp,
    command: sdk_e1_command(
      robobook_root,
      sidecar_path~,
      host~,
      port~,
      snapshot_path~,
      command_path~,
    ),
    env: sdk_environment(default_sdk_root()),
    contract_path: @bridge_protocol.route_for_operation(Contract).path,
    health_path: @bridge_protocol.route_for_operation(Health).path,
    telemetry_path: @bridge_protocol.route_for_operation(LatestTelemetry).path,
    execute_path: @bridge_protocol.route_for_operation(ExecuteIntent).path,
    mode: "control-gated",
    supervision: RestartOnFailure,
  }
}

///|
pub fn spec_json(spec : BridgeSidecarSpec, indent~ : Int32 = 2) -> String {
  spec.to_json().stringify(indent~)
}

///|
fn collector_process(
  profile : @core.RobotProfile,
  snapshot_path : String,
  collector_path : String?,
  python_path : String,
  backend : SdkE1Backend,
  library_path : String?,
  sdk_root : String,
) -> RuntimeProcessSpec {
  {
    process_id: "\{sidecar_id(profile)}:collector",
    role: SnapshotCollector,
    command: sdk_e1_collector_command(
      collector_path?,
      python_path~,
      backend~,
      library_path?,
      sdk_root~,
      snapshot_path~,
    ),
    env: sdk_environment(sdk_root),
    cwd: ".",
    output_path: snapshot_path,
    health_path: "",
    depends_on: [],
    supervision: RestartOnFailure,
  }
}

///|
fn writer_process(
  profile : @core.RobotProfile,
  command_path : String,
  writer_path : String?,
  python_path : String,
  backend : SdkE1Backend,
  library_path : String?,
  sdk_root : String,
) -> RuntimeProcessSpec {
  {
    process_id: "\{sidecar_id(profile)}:writer",
    role: HighControlWriter,
    command: sdk_e1_writer_command(
      writer_path?,
      python_path~,
      backend~,
      library_path?,
      sdk_root~,
      command_path~,
    ),
    env: sdk_environment(sdk_root),
    cwd: ".",
    output_path: command_path,
    health_path: "",
    depends_on: [],
    supervision: RestartOnFailure,
  }
}

///|
fn bridge_process(
  profile : @core.RobotProfile,
  robobook_root : String,
  sidecar_path : String,
  host : String,
  port : Int32,
  snapshot_path : String,
  command_path : String,
) -> RuntimeProcessSpec {
  let spec = spec_for_profile(
    profile,
    robobook_root,
    sidecar_path~,
    host~,
    port~,
    snapshot_path~,
    command_path~,
  )
  {
    process_id: "\{sidecar_id(profile)}:bridge",
    role: BridgeSidecar,
    command: spec.command,
    env: spec.env,
    cwd: ".",
    output_path: "",
    health_path: spec.health_path,
    depends_on: [
      "\{sidecar_id(profile)}:collector",
      "\{sidecar_id(profile)}:writer",
    ],
    supervision: spec.supervision,
  }
}

///|
pub fn runtime_spec_for_profile(
  profile : @core.RobotProfile,
  robobook_root : String,
  sidecar_path~ : String = default_sdk_e1_sidecar_path(),
  collector_path? : String,
  writer_path? : String,
  python_path~ : String = default_python_path(),
  backend~ : SdkE1Backend = default_sdk_e1_backend(),
  library_path? : String,
  sdk_root~ : String = default_sdk_root(),
  host~ : String = default_bridge_host(),
  port~ : Int32 = default_bridge_port(),
  snapshot_path~ : String = default_snapshot_path(),
  command_path~ : String = default_command_path(),
) -> PhysicalRuntimeSpec {
  {
    runtime_id: sidecar_id(profile),
    robot_id: profile.id,
    bridge_id: profile.bridge.id,
    snapshot_path,
    command_path,
    bridge_base_url: "http://\{host}:\{port}",
    processes: [
      collector_process(
        profile, snapshot_path, collector_path, python_path, backend, library_path,
        sdk_root,
      ),
      writer_process(
        profile, command_path, writer_path, python_path, backend, library_path, sdk_root,
      ),
      bridge_process(
        profile, robobook_root, sidecar_path, host, port, snapshot_path, command_path,
      ),
    ],
  }
}

///|
pub fn runtime_spec_json(
  spec : PhysicalRuntimeSpec,
  indent~ : Int32 = 2,
) -> String {
  spec.to_json().stringify(indent~)
}

///|
fn command_path(spec : BridgeSidecarSpec) -> String {
  if spec.command.is_empty() {
    ""
  } else {
    spec.command[0]
  }
}

///|
pub fn status_for_spec(
  spec : BridgeSidecarSpec,
  command_available : Bool,
) -> BridgeSidecarStatus {
  let path = command_path(spec)
  let state = if command_available { Launchable } else { MissingCommand }
  {
    sidecar_id: spec.sidecar_id,
    bridge_id: spec.bridge_id,
    robot_id: spec.robot_id,
    state,
    command_path: path,
    command_available,
    protocol_version: spec.protocol_version,
    contract_path: spec.contract_path,
    health_path: spec.health_path,
    execute_path: spec.execute_path,
    ready_for_execution: command_available,
    detail: if command_available {
      "bridge sidecar command is launchable"
    } else {
      "bridge sidecar command is missing: \{path}"
    },
  }
}

///|
pub fn status_json(status : BridgeSidecarStatus, indent~ : Int32 = 2) -> String {
  status.to_json().stringify(indent~)
}
