///|
struct Versions {
  warp : String
  isaaclab_revision : String
  newton_revision : String
  mujoco_warp : String
} derive(FromJson, ToJson)

///|
struct AssetIdentity {
  usd_sha256 : String
  mjcf_sha256 : String
} derive(FromJson, ToJson)

///|
struct GraphPaths {
  step : String
  reset : String
  context : String
  refresh : String
} derive(FromJson, ToJson)

///|
struct BundleFile {
  path : String
  sha256 : String
} derive(FromJson, ToJson)

///|
struct SharedRegion {
  name : String
  bytes : Int32
  scalar_type : String
} derive(FromJson, ToJson)

///|
struct BufferView {
  binding : String
  offset_elements : Int32
  row_stride_elements : Int32
  component_stride_elements : Int32
  width : Int32
} derive(FromJson, ToJson)

///|
struct WorldProperty {
  binding : String
  indices : Array[Array[Int32]]
} derive(FromJson, ToJson)

///|
struct GroundProperty {
  binding : String
  indices : Array[Int32]
} derive(FromJson, ToJson)

///|
struct ComProperty {
  binding : String
  indices : Array[Array[Int32]]
  base : Array[Array[Double]]
} derive(FromJson, ToJson)

///|
struct ContextWrites {
  shape_friction : WorldProperty
  ground_friction : GroundProperty
  torso_com : ComProperty
} derive(FromJson, ToJson)

///|
struct ImplicitCommandCapture {
  method : String
  target_kernel : String
  uses_actual_joint_map : Bool
  compute_processed_targets : Bool
  writes_effort_position_velocity : Bool
  writes_native_joint_act : Bool
  coordinate_scatter_preserved : Bool
  external_wrench_logic_preserved : Bool
  dirty_tendon_submission_preserved : Bool
  other_scene_writers_preserved : Bool
} derive(FromJson, ToJson)

///|
struct AllImplicitCapture {
  joint_count : Int32
  group_count : Int32
  all_groups_exact_implicit : Bool
  each_group_single_joint : Bool
  fixed_tendon_count : Int32
  execution_actuator_count : Int32
  native_group_count : Int32
  implicit_executor_present : Bool
  implicit_executor_group_count : Int32
  native_actuator_path_active : Bool
  manager_native_actuator_path_active : Bool
  adapter_present : Bool
  pre_actuator_callback_count : Int32
  post_actuator_callback_count : Int32
  post_step_callback_count : Int32
  post_step_callbacks_preserved : Bool
  scene_write_data_to_sim_included : Bool
  command_submission : ImplicitCommandCapture?
} derive(FromJson, ToJson)

///|
fn AllImplicitCapture::validate_commands(
  self : AllImplicitCapture,
) -> Unit raise {
  match (self.scene_write_data_to_sim_included, self.command_submission) {
    (true, None) => ()
    (false, Some(c)) => {
      guard c.method == "pinned_implicit_target_kernel" &&
        c.target_kernel ==
        "isaaclab.assets.articulation.ordering_kernels.launch_reorder_joint_targets_user_to_backend" &&
        c.uses_actual_joint_map &&
        c.compute_processed_targets &&
        c.writes_effort_position_velocity &&
        !c.writes_native_joint_act &&
        c.coordinate_scatter_preserved &&
        c.external_wrench_logic_preserved &&
        c.dirty_tendon_submission_preserved &&
        c.other_scene_writers_preserved else {
        fail(
          "implicit APIC target-kernel composition omits original SDK operations",
        )
      }
    }
    _ =>
      fail(
        "implicit APIC command submission has contradictory or missing provenance",
      )
  }
}

///|
struct CaptureContract {
  physics_steps_per_control : Int32
  uses_single_state : Bool
  uncaptured_manager_simulate_full : Bool
  // Legacy full captures include the configured manager adapter section. A
  // pure implicit capture instead records its exact runtime proof below and
  // captures write_data_to_sim before the original physics-only SDK operation.
  includes_actuator_adapter : Bool
  step_method : String?
  all_implicit_capture : AllImplicitCapture?
  context_model_change_flags : Array[String]
  reset_clears_solver_warm_start : Bool
  persistent_numeric_union_complete : Bool
  update_data_interval : Int32
  broadphase : String
} derive(FromJson, ToJson)

///|
fn CaptureContract::validate_step(self : CaptureContract) -> Unit raise {
  match (self.step_method, self.all_implicit_capture) {
    (None | Some("_simulate_full"), None) => {
      guard self.uncaptured_manager_simulate_full &&
        self.includes_actuator_adapter else {
        fail("full APIC capture must include the manager actuator section")
      }
    }
    (Some("_simulate_physics_only"), Some(p)) => {
      guard !self.uncaptured_manager_simulate_full &&
        !self.includes_actuator_adapter &&
        p.joint_count == 29 &&
        p.group_count == 29 &&
        p.all_groups_exact_implicit &&
        p.each_group_single_joint &&
        p.fixed_tendon_count == 0 &&
        p.execution_actuator_count == 0 &&
        p.native_group_count == 0 &&
        p.implicit_executor_present &&
        p.implicit_executor_group_count == 29 &&
        !p.native_actuator_path_active &&
        !p.manager_native_actuator_path_active &&
        !p.adapter_present &&
        p.pre_actuator_callback_count == 0 &&
        p.post_actuator_callback_count == 0 &&
        p.post_step_callback_count >= 0 &&
        p.post_step_callbacks_preserved else {
        fail(
          "physics-only APIC capture lacks the complete plain implicit actuator proof",
        )
      }
      p.validate_commands()
    }
    _ => fail("unsupported or inconsistent APIC captured step method")
  }
}

///|
struct SolverConfig {
  njmax : Int32
  nconmax : Int32
  integrator : String
  cone : String
  use_mujoco_contacts : Bool
} derive(FromJson, ToJson)

///|
struct Manifest {
  format : String
  capacity_profile : String?
  versions : Versions
  num_envs : Int32
  asset : AssetIdentity
  usd_variants : Map[String, String]
  self_collisions : Bool
  control_dt_s : Double
  physics_dt_s : Double
  num_substeps : Int32
  joint_names : Array[String]
  graphs : GraphPaths
  files : Array[BundleFile]
  shared_regions : Array[SharedRegion]
  views : Map[String, BufferView]
  context_writes : ContextWrites
  env_origins : Array[Array[Double]]
  capture_contract : CaptureContract
  solver_cfg : SolverConfig
} derive(FromJson, ToJson)

///|
fn Manifest::profile(self : Manifest) -> @capacity.CapacityProfile raise {
  match self.capacity_profile {
    None => Initial
    Some(value) => @capacity.CapacityProfile::parse(value)
  }
}

///|
fn decode_bundle_manifest(
  value : Json,
  expected : @capacity.CapacityProfile,
) -> Manifest raise {
  guard value is Object(fields) else { fail("APIC manifest must be object") }
  let declared = match fields.get("capacity_profile") {
    None => @capacity.Initial
    Some(String(name)) => @capacity.CapacityProfile::parse(name)
    _ =>
      fail(
        "APIC capacity_profile must be an explicit profile string, not null or an inferred size",
      )
  }
  guard declared == expected else {
    fail("APIC manifest and caller capacity profiles differ")
  }
  let result : Manifest = @json.from_json(value)
  guard result.profile() == expected else {
    fail("decoded APIC profile differs")
  }
  result
}

///|
fn relative_path(path : String) -> Bool {
  !path.is_empty() &&
  @utf8.encode(path).length() <= 4096 &&
  !path.has_prefix("/") &&
  !path.contains("\\") &&
  !path.contains(":") &&
  !path.contains("\u{0}") &&
  path.iter().all(c => c >= ' ' && c != '\u{7f}') &&
  path.split("/").count() <= 16 &&
  path
  .split("/")
  .all(part => {
    part != "" &&
    part != "." &&
    part != ".." &&
    @utf8.encode(part.to_string()).length() <= 255
  })
}

///|
fn scalar_size(kind : String) -> Int32 raise {
  match kind {
    "bool" | "uint8" => 1
    "float32" | "int32" => 4
    "float64" | "int64" => 8
    _ => fail("nonprimitive or unsupported APIC shared region dtype")
  }
}

///|
fn Manifest::validate(
  self : Manifest,
  expected_asset_sha256 : String,
  self_collisions : Bool,
) -> Unit raise {
  self.validate_resource_limits()
  guard self.format == "moonrobo.aligned-apic-bundle.v1" &&
    self.versions.warp == "1.17.0" &&
    self.versions.isaaclab_revision ==
    "46d6cc3d7b115906fad12efd372fbf69f4e3d3ed" &&
    self.versions.newton_revision == "71eeba16a717d4dcf0b9dd7056a7b6f863054dc3" &&
    self.versions.mujoco_warp == "3.15.0" else {
    fail("unsupported APIC bundle format/SDK pin")
  }
  guard self.num_envs > 0 &&
    self.num_envs <= bundle_limits(self.profile()).environments &&
    self.asset.mjcf_sha256 == expected_asset_sha256 &&
    self.asset.usd_sha256.length() == 64 &&
    self.self_collisions == self_collisions &&
    self.joint_names == @aligned.joint_names() &&
    self.control_dt_s == 0.02 &&
    self.physics_dt_s == 0.005 &&
    self.num_substeps == 4 else {
    fail("APIC artifact asset/joints/batch/physics configuration differs")
  }
  for name, selection in self.usd_variants {
    guard !name.is_empty() &&
      !selection.is_empty() &&
      !name.contains("\u{0}") &&
      !selection.contains("\u{0}") else {
      fail("invalid explicit USD variant selection")
    }
  }
  let c = self.capture_contract
  guard self.solver_cfg.njmax == 500 &&
    self.solver_cfg.nconmax == 128 &&
    self.solver_cfg.integrator == "implicitfast" &&
    self.solver_cfg.cone == "pyramidal" &&
    self.solver_cfg.use_mujoco_contacts else {
    fail(
      "APIC solver configuration differs from the pinned aligned Isaac backend",
    )
  }
  guard c.physics_steps_per_control == 4 &&
    c.uses_single_state &&
    c.reset_clears_solver_warm_start &&
    c.persistent_numeric_union_complete &&
    c.update_data_interval == 1 &&
    c.context_model_change_flags.contains("SHAPE_PROPERTIES") &&
    c.context_model_change_flags.contains("BODY_INERTIAL_PROPERTIES") &&
    !c.broadphase.is_empty() else {
    fail(
      "APIC capture does not declare the complete pinned physical operation contract",
    )
  }
  c.validate_step()
  guard self.env_origins.length() == self.num_envs &&
    self.env_origins.all(row => {
      row.length() == 3 && row.all(v => !v.is_nan() && !v.is_inf())
    }) else {
    fail("APIC bundle needs actual finite per-world origins")
  }
  guard !self.shared_regions.is_empty() else {
    fail("APIC bundle has no persistent numeric union")
  }
  let regions : Map[String, SharedRegion] = {}
  for region in self.shared_regions {
    let scalar = scalar_size(region.scalar_type)
    guard !region.name.is_empty() &&
      !region.name.contains("\u{0}") &&
      region.bytes > 0 &&
      region.bytes % scalar == 0 &&
      !regions.contains(region.name) else {
      fail("invalid/duplicate APIC shared base region")
    }
    regions[region.name] = region
  }
  let widths : Map[String, Int32] = {
    "root_pose": 7,
    "root_com_velocity": 6,
    "root_com_local": 3,
    "joint_position": 29,
    "joint_velocity": 29,
    "targets": 29,
    "reset_pose": 7,
    "reset_velocity": 6,
    "reset_joint_position": 29,
    "reset_joint_velocity": 29,
    "reset_mask": 1,
  }
  for name, width in widths {
    guard self.views.get(name) is Some(view) &&
      view.width == width &&
      regions.get(view.binding) is Some(region) else {
      fail("missing APIC component view or persistent base allocation: " + name)
    }
    let scalar = if name == "reset_mask" { 1 } else { 4 }
    guard region.scalar_type == (if scalar == 1 { "bool" } else { "float32" }) &&
      view.offset_elements >= 0 &&
      view.row_stride_elements >= 0 &&
      view.component_stride_elements > 0 else {
      fail("invalid APIC component view dtype/strides")
    }
    // Int64 arithmetic is safe here: every operand is bounded by Int32; the
    // product of two nonnegative Int32 values is at most 2^62.
    let last = view.offset_elements.to_int64() +
      (self.num_envs - 1).to_int64() * view.row_stride_elements.to_int64() +
      (width - 1).to_int64() * view.component_stride_elements.to_int64()
    guard last >= 0L && last < region.bytes.to_int64() / scalar.to_int64() else {
      fail("APIC component view exceeds allocation capacity")
    }
  }
  guard self.views.length() == widths.length() else {
    fail("unknown APIC component view")
  }
  let input_bindings = []
  let state_bindings = [
    "root_pose", "root_com_velocity", "root_com_local", "joint_position", "joint_velocity",
  ].map(name => {
    self.views.get_or_default(name, {
      binding: "",
      offset_elements: 0,
      row_stride_elements: 0,
      component_stride_elements: 1,
      width: 0,
    }).binding
  })
  for
    name in [
      "targets", "reset_pose", "reset_velocity", "reset_joint_position", "reset_joint_velocity",
      "reset_mask",
    ] {
    let view = self.views.get_or_default(name, {
      binding: "",
      offset_elements: 0,
      row_stride_elements: 0,
      component_stride_elements: 1,
      width: 0,
    })
    guard !input_bindings.contains(view.binding) &&
      !state_bindings.contains(view.binding) &&
      view.row_stride_elements.to_int64() >
      (view.width - 1).to_int64() * view.component_stride_elements.to_int64() else {
      fail(
        "APIC input buffers must be distinct nonoverlapping per-world allocations",
      )
    }
    input_bindings.push(view.binding)
  }
  let ctx = self.context_writes
  guard ctx.shape_friction.indices.length() == self.num_envs &&
    ctx.torso_com.indices.length() == self.num_envs &&
    ctx.torso_com.base.length() == self.num_envs &&
    !ctx.ground_friction.indices.is_empty() else {
    fail("incomplete APIC physical-context index map")
  }
  let occupied : Map[String, Map[Int32, Bool]] = {}
  let add = (binding : String, indices : Array[Int32]) => {
    guard regions.get(binding) is Some(region) &&
      region.scalar_type == "float32" else {
      fail("physical context requires shared float32 model array")
    }
    let prior = occupied.get_or_default(binding, {})
    for index in indices {
      guard index >= 0 && index < region.bytes / 4 && !prior.contains(index) else {
        fail("invalid/overlapping physical context property index")
      }
      prior[index] = true
    }
    occupied[binding] = prior
  }
  for row in ctx.shape_friction.indices {
    guard !row.is_empty() else {
      fail("GPU world has no robot friction shapes")
    }
    add(ctx.shape_friction.binding, row)
  }
  add(ctx.ground_friction.binding, ctx.ground_friction.indices)
  for i, row in ctx.torso_com.indices {
    guard row.length() == 3 &&
      ctx.torso_com.base[i].length() == 3 &&
      ctx.torso_com.base[i].all(v => !v.is_nan() && !v.is_inf()) else {
      fail("invalid torso COM context map")
    }
    add(ctx.torso_com.binding, row)
  }
  let paths : Map[String, Bool] = {}
  for file in self.files {
    guard relative_path(file.path) &&
      bundle_sha256(file.sha256) &&
      !paths.contains(file.path) else {
      fail("invalid/duplicate bundle file/hash")
    }
    paths[file.path] = true
  }
  let graph_paths : Map[String, Bool] = {}
  for
    path in [
      self.graphs.step,
      self.graphs.reset,
      self.graphs.context,
      self.graphs.refresh,
    ] {
    guard relative_path(path) &&
      path.has_suffix(".wrp") &&
      paths.contains(path) &&
      !graph_paths.contains(path) else {
      fail("graph file is absent from artifact hash inventory")
    }
    graph_paths[path] = true
  }
}

///|
async fn validate_bundle(
  bundle_manifest : String,
  expected_asset_sha256 : String,
  self_collisions : Bool,
  expected_manifest_sha256 : String?,
  capacity_profile~ : @capacity.CapacityProfile = Initial,
) -> VerifiedBundle {
  let (manifest_file, data) = bounded_bundle_manifest(
    bundle_manifest,
    capacity_profile~,
  )
  let digest = @artifacts.sha256(data)
  if expected_manifest_sha256 is Some(expected) {
    guard digest == expected else { fail("APIC manifest SHA256 mismatch") }
  }
  let manifest = decode_bundle_manifest(
    @json.parse(@utf8.decode(data)),
    capacity_profile,
  )
  manifest.validate(expected_asset_sha256, self_collisions)
  let parts = manifest_file.path.split("/").to_array()
  let directory = parts[0:parts.length() - 1].join("/")
  let identities = [manifest_file]
  let file_sizes : Map[String, Int64] = {}
  let mut total = 0L
  // Stat the complete inventory before reading any graph or module payload.
  for file in manifest.files {
    let identity = bundle_file_identity(
      bundle_payload_path(directory, file.path),
      bundle_limits(capacity_profile).member,
    )
    total = add_bundle_bytes(total, identity.bytes, capacity_profile~)
    identities.push(identity)
    file_sizes[file.path] = identity.bytes
  }
  for i, file in manifest.files {
    guard hash_bundle_file(identities[i + 1]) == file.sha256 else {
      fail("APIC bundle file SHA256 mismatch: " + file.path)
    }
  }
  let verified : VerifiedBundle = {
    manifest,
    digest,
    directory,
    identities,
    resources: manifest.resource_summary(file_sizes),
  }
  verified.assert_unchanged()
  verified
}

///|
/// Check the fixed Newton artifact, complete file inventory and SHA256 values
/// without opening CUDA or loading the APIC adapter. Deploy each physical node
/// with the same returned manifest digest before starting a training worker.
pub async fn inspect_bundle(
  bundle_manifest : String,
  expected_asset_sha256 : String,
  self_collisions~ : Bool = true,
  expected_manifest_sha256? : String,
  adapter_library? : String,
  capacity_profile~ : @capacity.CapacityProfile = Initial,
) -> Json {
  let verified = validate_bundle(
    bundle_manifest,
    expected_asset_sha256,
    self_collisions,
    expected_manifest_sha256,
    capacity_profile~,
  )
  let manifest = verified.manifest
  let digest = verified.digest
  {
    "artifact_manifest_sha256": digest.to_json(),
    "num_envs": manifest.num_envs.to_json(),
    "capacity_profile": Json(manifest.profile().name()),
    "asset": manifest.asset.to_json(),
    "versions": manifest.versions.to_json(),
    "solver_cfg": manifest.solver_cfg.to_json(),
    "capture_contract": manifest.capture_contract.to_json(),
    "self_collisions": manifest.self_collisions.to_json(),
    "file_count": manifest.files.length().to_json(),
    "resources": verified.resources,
    "adapter_library_sha256": match adapter_library {
      Some(path) => validated_adapter(path).1.to_json()
      None => Json::null()
    },
  }
}

///|
/// Validate hashes before entering any CUDA/SDK call. This is a native replay
/// of an explicitly generated trusted artifact; it never constructs a substitute
/// simulator when CUDA, matching Warp or the artifact is unavailable.
pub async fn load(
  adapter_library : String,
  bundle_manifest : String,
  expected_asset_sha256 : String,
  self_collisions~ : Bool = true,
  device_id~ : Int32 = 0,
  expected_manifest_sha256? : String,
  capacity_profile~ : @capacity.CapacityProfile = Initial,
) -> NativeBatch {
  guard device_id >= 0 else { fail("CUDA device index must be nonnegative") }
  let verified = validate_bundle(
    bundle_manifest,
    expected_asset_sha256,
    self_collisions,
    expected_manifest_sha256,
    capacity_profile~,
  )
  let manifest = verified.manifest
  let digest = verified.digest
  let directory = verified.directory
  let (library_identity, library_sha256) = validated_adapter(adapter_library)
  verified.assert_unchanged()
  assert_bundle_identity(library_identity)
  let handle = open_native(
    c_string(library_identity.path),
    device_id,
    manifest.num_envs,
  )
  guard @utf8.decode_lossy(error_native(handle)) == "" else {
    fail(
      "native APIC initialization: " + @utf8.decode_lossy(error_native(handle)),
    )
  }
  errdefer close_native(handle)
  for
    role, path in [
      manifest.graphs.step,
      manifest.graphs.reset,
      manifest.graphs.context,
      manifest.graphs.refresh,
    ] {
    checked(
      handle,
      graph_native(handle, role, c_string(directory + "/" + path)),
    )
  }
  for region in manifest.shared_regions {
    checked(
      handle,
      share_native(
        handle,
        c_string(region.name),
        region.bytes.to_int64(),
        scalar_size(region.scalar_type),
      ),
    )
  }
  for name, view in manifest.views {
    checked(
      handle,
      view_native(
        handle,
        c_string(name),
        c_string(view.binding),
        view.offset_elements.to_int64(),
        view.row_stride_elements.to_int64(),
        view.component_stride_elements.to_int64(),
        view.width,
        if name == "reset_mask" {
          1
        } else {
          4
        },
      ),
    )
  }
  for id, origin in manifest.env_origins {
    checked(handle, origin_native(handle, id, origin[0], origin[1], origin[2]))
  }
  // Native APIC opens graph/module paths itself. Refuse observable changes
  // through that loading interval before the first graph operation. This is
  // not a filesystem snapshot; deployments must keep the bundle immutable.
  verified.assert_unchanged()
  assert_bundle_identity(library_identity)
  checked(handle, operation_native(handle, 0))
  {
    handle,
    manifest,
    provenance: {
      "backend": "isaac-newton-mujoco-warp-apic",
      "artifact_manifest": bundle_manifest.to_json(),
      "artifact_manifest_sha256": digest.to_json(),
      "adapter_library": adapter_library.to_json(),
      "adapter_library_sha256": library_sha256.to_json(),
      "resources": verified.resources,
      "cuda_device_index": device_id.to_json(),
      "num_envs": manifest.num_envs.to_json(),
      "capacity_profile": Json(manifest.profile().name()),
      "asset": manifest.asset.to_json(),
      "usd_variants": manifest.usd_variants.to_json(),
      "versions": manifest.versions.to_json(),
      "capture_contract": manifest.capture_contract.to_json(),
      "solver_cfg": manifest.solver_cfg.to_json(),
      "physics_substeps": 4,
      "physics_dt_s": 0.005,
      "control_dt_s": 0.02,
      "self_collisions": self_collisions.to_json(),
      "exact_resume": false,
      "replay_refill_required": true,
      "python_runtime_used": false,
    },
  }
}
