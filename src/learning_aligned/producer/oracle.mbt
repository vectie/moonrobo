///|
struct OracleOperation {
  id : String
  kind : String
  ids : Array[Int32]
  states71 : Array[Array[Double]]
  targets : Array[Array[Double]]
  context : Array[Array[Double]]
  ground_mu : Double
} derive(FromJson)

///|
struct OracleTape {
  format : String
  num_envs : Int32
  selected_worlds : Array[Int32]?
  operations : Array[OracleOperation]
} derive(FromJson)

///|
struct OracleViews {
  root_com : PyValue
  torso_com : PyValue
  shape_friction : PyValue
  ground_indices : Array[Int32]
  torso_base : Array[Array[Double]]
  origins : Array[Array[Double]]
}

///|
fn matrix(value : Json) -> Array[Array[Double]] raise {
  @json.from_json(value)
}

///|
fn Scene::oracle_views(self : Scene) -> OracleViews raise {
  let py = self.py
  let root = self.robot.attr("root_view")
  let names : Array[String] = @json.from_json(root.attr("link_names").json())
  guard names.length() > 0 &&
    names[0] == "pelvis" &&
    names.find_index(n => n == "torso_link") is Some(torso) else {
    fail("SDK oracle requires the original pelvis and torso body bindings")
  }
  let com = py.method(root, "get_attribute", args=[
    py.literal("body_com"),
    self.model,
  ])
  let torso_com = py.slice(com, [None, Some(0), Some(torso)])
  let shape_friction = py.slice(
    py.method(root, "get_attribute", args=[
      py.literal("shape_material_mu"),
      self.model,
    ]),
    [None, Some(0)],
  )
  let bodies = integers(self.host(self.model.attr("shape_body")))
  let ground_indices = []
  for i, body in bodies {
    if body < 0 {
      ground_indices.push(i)
    }
  }
  guard !ground_indices.is_empty() else {
    fail("SDK oracle has no ground shapes")
  }
  {
    root_com: py.slice(com, [None, Some(0), Some(0)]),
    torso_com,
    shape_friction,
    ground_indices,
    torso_base: matrix(self.host(torso_com)),
    origins: matrix(self.host(self.scene.attr("env_origins"))),
  }
}

///|
// Outside capture, genuine Warp assign accepts both contiguous and strided
// arrays. This deliberately exercises the original SDK path without the APIC
// command-copy workaround. Inputs contain only the bounded audit's N worlds.
fn Scene::oracle_assign(
  self : Scene,
  destination : PyValue,
  value : Json,
) -> Unit raise {
  let source = self.py.call(self.wp.attr("array"), kw=[
    ("data", self.py.literal(value)),
    ("dtype", destination.attr("dtype")),
    ("device", destination.attr("device")),
  ])
  ignore(self.py.method(destination, "assign", args=[source]))
}

///|
fn oracle_state71(
  pose : Array[Double],
  velocity : Array[Double],
  com : Array[Double],
  q : Array[Double],
  qd : Array[Double],
  origin : Array[Double],
) -> Array[Double] {
  let quat = [pose[6], pose[3], pose[4], pose[5]]
  let offset = @aligned.mat_vec(@aligned.quat_to_mat(quat), com)
  let w = velocity[3:6].to_array()
  let cross = @aligned.cross(w, offset)
  let state = Array::make(71, 0.0)
  for i in 0..<3 {
    state[i] = pose[i] - origin[i]
    state[7 + i] = velocity[i] - cross[i]
    state[10 + i] = w[i]
  }
  for i in 0..<4 {
    state[3 + i] = quat[i]
  }
  for i in 0..<29 {
    state[13 + i] = q[i]
    state[42 + i] = qd[i]
  }
  state
}

///|
fn Scene::oracle_selected_rows(
  self : Scene,
  value : PyValue,
  selected : Array[Int32],
) -> Array[Array[Double]] raise {
  let value = if value.has_attr("warp") { value.attr("warp") } else { value }
  let shape = integers(value.attr("shape").json())
  guard value.is_instance(self.wp.attr("array")) &&
    !shape.is_empty() &&
    shape[0] == self.inputs["num_envs"].int() else {
    fail("SDK selected readback requires an actual per-world array")
  }
  let (_, scalar_bytes) = self.classify(value.attr("dtype"))
  let dtype_bytes = self.py
    .call(self.py.module("warp._src.types").attr("type_size_in_bytes"), args=[
      value.attr("dtype"),
    ])
    .int()
  let mut row_scalars = (dtype_bytes / scalar_bytes).to_int64()
  guard row_scalars > 0L && row_scalars <= 4096L else {
    fail("SDK selected readback scalar width exceeds bound")
  }
  for dimension in shape[1:] {
    guard dimension > 0 && row_scalars <= 4096L / dimension.to_int64() else {
      fail("SDK selected readback row exceeds 4096 values before transfer")
    }
    row_scalars *= dimension.to_int64()
  }
  // Preserve the leading axis: integer indexing of a one-dimensional Warp
  // vector array is unsupported. A genuine [world:world+1] view copies only
  // that row to host, including when the underlying world stride is larger.
  selected.map(world => {
    let slice = self.py.call(self.py.module("builtins").attr("slice"), args=[
      self.py.literal(Json(world)),
      self.py.literal(Json(world + 1)),
    ])
    let rows = matrix(self.host(value.item(slice)))
    guard rows.length() == 1 &&
      rows[0].length() > 0 &&
      rows[0].length() <= 4096 &&
      rows[0].all(oracle_finite) else {
      fail("SDK selected readback row is invalid or exceeds 4096 values")
    }
    rows[0]
  })
}

///|
fn Scene::oracle_readback(
  self : Scene,
  views : OracleViews,
  selected? : Array[Int32],
) -> Json raise {
  let data = self.robot.attr("data")
  // Keep v1's original full N2 readback schedule intact. V2 selects rows before
  // transfer/JSON conversion rather than copying an N-by-body output to host.
  let read = fn(value : PyValue) -> Array[Array[Double]] raise {
    match selected {
      None => matrix(self.host(value))
      Some(ids) => self.oracle_selected_rows(value, ids)
    }
  }
  let worlds = selected.unwrap_or(
    Array::makei(self.inputs["num_envs"].int(), i => i),
  )
  let pose = read(data.attr("root_link_pose_w"))
  let velocity = read(data.attr("root_com_vel_w"))
  let com = read(views.root_com)
  let q = read(data.attr("joint_pos"))
  let qd = read(data.attr("joint_vel"))
  let ground_mu = match selected {
    None => {
      let mu = floats(self.host(self.model.attr("shape_material_mu")))
      views.ground_indices.map(i => mu[i])
    }
    Some(_) => {
      guard views.ground_indices.length() <= 4096 else {
        fail("SDK oracle ground readback exceeds 4096 static shapes")
      }
      let mu = self.model.attr("shape_material_mu")
      views.ground_indices.map(i => {
        let slice = self.py.call(self.py.module("builtins").attr("slice"), args=[
          self.py.literal(Json(i)),
          self.py.literal(Json(i + 1)),
        ])
        let values = floats(self.host(mu.item(slice)))
        guard values.length() == 1 && oracle_finite(values[0]) else {
          fail("SDK oracle static friction readback is invalid")
        }
        values[0]
      })
    }
  }
  let state = Array::makei(worlds.length(), i => {
    oracle_state71(
      pose[i],
      velocity[i],
      com[i],
      q[i],
      qd[i],
      views.origins[worlds[i]],
    )
  })
  guard state.all(row => row.all(x => !x.is_nan() && !x.is_inf())) else {
    fail("SDK oracle returned nonfinite physical state")
  }
  {
    "state71": Json(state),
    "root_pose": Json(pose),
    "root_com_velocity": Json(velocity),
    "root_com_local": Json(com),
    "joint_position": Json(q),
    "joint_velocity": Json(qd),
    "shape_friction": Json(read(views.shape_friction)),
    "torso_com": Json(read(views.torso_com)),
    "ground_friction": Json(ground_mu),
  }
}

///|
fn Scene::oracle_reset(
  self : Scene,
  views : OracleViews,
  op : OracleOperation,
) -> Unit raise {
  if op.ids.is_empty() {
    return
  }
  let py = self.py
  let com = matrix(self.host(views.root_com))
  let n = self.inputs["num_envs"].int()
  let mask = Array::make(n, false)
  let pose = Array::makei(n, _ => [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0])
  let velocity = Array::makei(n, _ => Array::make(6, 0.0))
  let q = Array::makei(n, _ => Array::make(29, 0.0))
  let qd = Array::makei(n, _ => Array::make(29, 0.0))
  for k, id in op.ids {
    let state = op.states71[k]
    mask[id] = true
    let quat = state[3:7].to_array()
    let offset = @aligned.mat_vec(@aligned.quat_to_mat(quat), com[id])
    let w = state[10:13].to_array()
    let cross = @aligned.cross(w, offset)
    for j in 0..<3 {
      pose[id][j] = state[j] + views.origins[id][j]
      velocity[id][j] = state[7 + j] + cross[j]
      velocity[id][3 + j] = w[j]
    }
    pose[id][3] = quat[1]
    pose[id][4] = quat[2]
    pose[id][5] = quat[3]
    pose[id][6] = quat[0]
    for j in 0..<29 {
      q[id][j] = state[13 + j]
      qd[id][j] = state[42 + j]
    }
  }
  self.oracle_assign(self.inputs["reset_mask"], Json(mask))
  self.oracle_assign(self.inputs["reset_pose"], Json(pose))
  self.oracle_assign(self.inputs["reset_velocity"], Json(velocity))
  self.oracle_assign(self.inputs["reset_joint_position"], Json(q))
  self.oracle_assign(self.inputs["reset_joint_velocity"], Json(qd))
  // Call the untouched public SDK mask writers, including their ProxyArray
  // outputs. No APIC recording is active and no lowered reset helper is used.
  for
    (name, keyword, input) in [
      ("write_root_link_pose_to_sim_mask", "root_pose", "reset_pose"),
      ("write_root_com_velocity_to_sim_mask", "root_velocity", "reset_velocity"),
      ("write_joint_position_to_sim_mask", "position", "reset_joint_position"),
      ("write_joint_velocity_to_sim_mask", "velocity", "reset_joint_velocity"),
    ] {
    ignore(
      py.method(self.robot, name, kw=[
        (keyword, self.inputs[input]),
        ("env_mask", self.inputs["reset_mask"]),
      ]),
    )
  }
  ignore(
    py.method(self.robot, "set_joint_position_target_mask", kw=[
      ("target", self.inputs["reset_joint_position"]),
      ("env_mask", self.inputs["reset_mask"]),
    ]),
  )
  ignore(
    py.method(
      self.solver,
      "reset",
      args=[py.method(self.manager, "get_state_0")],
      kw=[
        ("world_mask", self.manager.attr("_world_reset_mask")),
        ("flags", py.literal(0)),
      ],
    ),
  )
  ignore(py.method(self.manager, "forward"))
  self.force_queries()
  // NativeBatch.reset performs its normal post-reset refresh too.
  ignore(py.method(self.manager, "forward"))
  self.force_queries()
}

///|
fn Scene::oracle_operation(
  self : Scene,
  views : OracleViews,
  op : OracleOperation,
  writer_records~ : Array[Json]? = None,
) -> Unit raise {
  let py = self.py
  match op.kind {
    "reset" => self.oracle_reset(views, op)
    "step" => {
      self.oracle_assign(self.inputs["targets"], Json(op.targets))
      ignore(
        py.method(self.robot, "set_joint_position_target_mask", kw=[
          ("target", self.inputs["targets"]),
          ("env_mask", self.all_worlds),
        ]),
      )
      // Independent oracle: original scene writer and SimulationContext step,
      // never write_scene_commands, write_root_reset or a saved graph.
      match writer_records {
        None => ignore(py.method(self.scene, "write_data_to_sim"))
        Some(records) => self.diagnostic_writer(views, op.id, records)
      }
      ignore(py.method(self.sim, "step", kw=[("render", py.literal(false))]))
      self.force_queries(dt=0.02)
    }
    "context" => {
      let friction = matrix(self.host(views.shape_friction))
      let com = matrix(self.host(views.torso_com))
      for k, id in op.ids {
        friction[id] = Array::make(friction[id].length(), op.context[k][0])
        com[id] = Array::makei(3, j => {
          views.torso_base[id][j] + op.context[k][30 + j]
        })
      }
      self.oracle_assign(views.shape_friction, Json(friction))
      self.oracle_assign(views.torso_com, Json(com))
      let ground_array = self.model.attr("shape_material_mu")
      let ground = floats(self.host(ground_array))
      for i in views.ground_indices {
        ground[i] = op.ground_mu
      }
      self.oracle_assign(ground_array, Json(ground))
      ignore(
        py.method(self.solver, "notify_model_changed", args=[
          py.literal(Json(self.flags)),
        ]),
      )
      ignore(py.method(self.manager, "forward"))
      self.force_queries()
      // Match the public native context API's following refresh boundary.
      ignore(py.method(self.manager, "forward"))
      self.force_queries()
    }
    "refresh" => {
      ignore(py.method(self.manager, "forward"))
      self.force_queries()
    }
    _ => fail("unsupported SDK oracle operation")
  }
}

///|
async fn oracle_bytes(path : String, max_bytes~ : Int64 = 4194304L) -> Bytes {
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  let size = file.size()
  guard size > 0L && size <= max_bytes else {
    fail("oracle input exceeds the selected bounded file limit")
  }
  let bytes = file.read_exactly_at(size.to_int(), position=0L)
  guard file.size() == size else {
    fail("oracle input changed during bounded read")
  }
  bytes
}

///|
/// Execute a bounded audit tape through the original eager SDK. V1 remains the
/// exact pinned two-world fixture; V2 names selected worlds explicitly.
/// This is real GPU work; it is never run by compilation or static checks.
pub async fn trace_sdk(
  config : ExportConfig,
  tape_path : String,
  bundle_manifest_path : String,
  output : String,
  diagnostic~ : Bool = false,
) -> Json {
  let profile = config.profile()
  guard config.num_envs >= 2 &&
    config.num_envs <= profile.limits().max_environments &&
    !@fs.exists(output) else {
    fail(
      "SDK oracle world count exceeds selected capacity profile or output exists",
    )
  }
  let tape_bytes = oracle_bytes(
    tape_path,
    max_bytes=profile.limits().max_apic_oracle_bytes,
  )
  let tape_sha = @artifacts.sha256(tape_bytes)
  let tape : OracleTape = @json.from_json(@json.parse(@utf8.decode(tape_bytes)))
  let selected = tape.validate(
    config.num_envs,
    tape_sha,
    diagnostic~,
    max_envs=profile.limits().max_environments,
  )
  let manifest_bytes = oracle_bytes(
    bundle_manifest_path,
    max_bytes=profile.limits().max_apic_manifest_bytes,
  )
  let manifest = @json.parse(@utf8.decode(manifest_bytes))
  guard (if manifest is { "capacity_profile": String(name), .. } {
    name == profile.name()
  } else {
    profile.name() == "initial"
  }) else {
    fail("SDK oracle capacity profile differs from bundle identity")
  }
  let usd_sha = @artifacts.sha256(@fs.read_file(config.usd).binary())
  let mjcf_sha = @artifacts.sha256(@fs.read_file(config.source_mjcf).binary())
  guard manifest
    is {
      "format": "moonrobo.aligned-apic-bundle.v1",
      "num_envs": env_count,
      "control_dt_s": 0.02,
      "physics_dt_s": 0.005,
      "num_substeps": 4,
      "joint_names": joint_names,
      "asset": {
        "usd_sha256": String(asset_usd),
        "mjcf_sha256": String(asset_mjcf),
        ..
      },
      "usd_variants": variants,
      "self_collisions": collisions,
      "versions": {
        "warp": "1.17.0",
        "isaaclab_revision": "46d6cc3d7b115906fad12efd372fbf69f4e3d3ed",
        "newton_revision": "71eeba16a717d4dcf0b9dd7056a7b6f863054dc3",
        "mujoco_warp": "3.15.0",
        ..
      },
      ..
    } &&
    env_count == Json(config.num_envs) &&
    asset_usd == usd_sha &&
    asset_mjcf == mjcf_sha &&
    variants == Json(config.usd_variants) &&
    collisions == Json(config.self_collisions) &&
    joint_names == Json(@aligned.joint_names()) else {
    fail(
      "SDK oracle scene/asset/versions differ from the actual bundle manifest",
    )
  }
  guard git_revision(config.isaaclab_root) ==
    "46d6cc3d7b115906fad12efd372fbf69f4e3d3ed" &&
    git_revision(config.newton_root) ==
    "71eeba16a717d4dcf0b9dd7056a7b6f863054dc3" else {
    fail("SDK oracle source revision mismatch")
  }
  let py = Interpreter::open(
    config.adapter,
    config.python,
    config.site_packages,
  )
  for
    (name, root) in [
      ("isaaclab", config.isaaclab_root),
      ("isaaclab_newton", config.isaaclab_root),
      ("newton", config.newton_root),
    ] {
    guard @fs.realpath(py.module(name).attr("__file__").text()).has_prefix(
      @fs.realpath(root) + "/",
    ) else {
      fail("SDK oracle imports must resolve inside the verified checkout")
    }
  }
  let scene = open_scene(py, config)
  defer (ignore(
    py.method(scene.launcher, "__exit__", args=[
      py.literal(Json::null()),
      py.literal(Json::null()),
      py.literal(Json::null()),
    ]),
  ) catch {
    _ => ()
  })
  scene.force_queries()
  let views = scene.oracle_views()
  let snapshots : Array[Json] = []
  let writer_records : Array[Json] = []
  let failure : String? = try {
    for op in tape.operations {
      scene.oracle_operation(
        views,
        op,
        writer_records=if diagnostic { Some(writer_records) } else { None },
      ) catch {
        error =>
          if diagnostic {
            fail("SDK diagnostic operation " + op.id + ": " + error.to_string())
          } else {
            raise error
          }
      }
      let snapshot : Map[String, Json] = {
        "id": Json(op.id),
        "readback": scene.oracle_readback(views, selected?),
      }
      if diagnostic {
        snapshot["diagnostic"] = {
          "inputs": scene.diagnostic_inputs(),
          "sdk_commands": scene.diagnostic_commands(),
          "solver": scene.diagnostic_solver(),
        }
      }
      snapshots.push(Json(snapshot))
    }
    None
  } catch {
    error => if diagnostic { Some(error.to_string()) } else { raise error }
  }
  let result : Json = {
    "format": Json(
      if diagnostic {
        "moonrobo.apic-sdk-diagnostic.v1"
      } else if selected is Some(_) {
        "moonrobo.apic-sdk-oracle.v2"
      } else {
        "moonrobo.apic-sdk-oracle.v1"
      },
    ),
    "bundle_manifest_sha256": Json(@artifacts.sha256(manifest_bytes)),
    "capacity_profile": Json(profile.name()),
    "tape_sha256": Json(tape_sha),
    "sdk_identity": {
      "implementation_backend": "actual-isaaclab3-newton",
      "warp": "1.17.0",
      "isaaclab_revision": "46d6cc3d7b115906fad12efd372fbf69f4e3d3ed",
      "newton_revision": "71eeba16a717d4dcf0b9dd7056a7b6f863054dc3",
      "mujoco_warp": "3.15.0",
      "scene_writer": "original_InteractiveScene.write_data_to_sim",
      "physics_step": "original_SimulationContext.step",
      "reset_writers": "original_public_mask_writers",
      "apic_capture": false,
      "authoring_bridge_sha256": Json(
        @artifacts.sha256(@fs.read_file(config.adapter).binary()),
      ),
      "asset_usd_sha256": Json(usd_sha),
      "asset_mjcf_sha256": Json(mjcf_sha),
    },
    "snapshots": Json(snapshots),
  }
  let result = match selected {
    None => result
    Some(worlds) => {
      let fields : Map[String, Json] = @json.from_json(result)
      fields["num_envs"] = Json(config.num_envs)
      fields["selected_worlds"] = Json(worlds)
      fields["readback_scope"] = "per-world rows follow selected_worlds; ground_friction contains every static ground shape"
      Json(fields)
    }
  }
  let result = if diagnostic {
    let fields : Map[String, Json] = @json.from_json(result)
    fields["success"] = Json(
      failure is None &&
      snapshots.length() == 20 &&
      writer_records.length() == 8,
    )
    fields["error"] = Json(failure)
    fields["writer_comparisons"] = Json(writer_records)
    fields["physics_equivalence_claimed"] = false
    fields["diagnostic_protocol"] = "original writer then finite output poison then lowered writer, exact comparison before any physics, restore original control outputs; original SDK physics step"
    fields["solver_internal_state_restored"] = false
    fields["substep_diagnostics_available"] = false
    Json(fields)
  } else {
    result
  }
  @fs.write_file(output, result.stringify(indent=2), create_mode=CreateNew)
  result
}
