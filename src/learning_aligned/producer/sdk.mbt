///|
/// Inputs for explicitly requested offline authoring, never for deployed replay.
pub(all) struct ExportConfig {
  adapter : String
  python : String
  site_packages : String
  isaaclab_root : String
  newton_root : String
  usd : String
  usd_variants : Map[String, String]
  source_mjcf : String
  output : String
  num_envs : Int32
  device_id : Int32
  self_collisions : Bool
  capacity_profile : String?
} derive(FromJson, ToJson)

///|
/// Historical JSON without this field keeps the original fixed N128 limits.
fn ExportConfig::profile(
  self : ExportConfig,
) -> @capacity.CapacityProfile raise {
  @capacity.CapacityProfile::parse(self.capacity_profile.unwrap_or("initial"))
}

///|
struct Scene {
  py : Interpreter
  wp : PyValue
  launcher : PyValue
  sim : PyValue
  scene : PyValue
  robot : PyValue
  manager : PyValue
  model : PyValue
  solver : PyValue
  device : PyValue
  targets : PyValue
  all_worlds : PyValue
  inputs : Map[String, PyValue]
  flags : Int32
  step_method : String
  all_implicit_capture : Json
}

///|
fn integer(value : Json) -> Int32 raise {
  @json.from_json(value)
}

///|
fn floats(value : Json) -> Array[Double] raise {
  @json.from_json(value)
}

///|
fn integers(value : Json) -> Array[Int32] raise {
  @json.from_json(value)
}

///|
fn PyValue::int(self : PyValue) -> Int32 raise {
  integer(self.json())
}

///|
fn PyValue::int64(self : PyValue) -> Int64 raise {
  @string.parse_int64(self.text())
}

///|
fn PyValue::bool(self : PyValue) -> Bool raise {
  @json.from_json(self.json())
}

///|
fn Interpreter::tuple(
  self : Interpreter,
  items : Array[PyValue],
) -> PyValue raise {
  self.call(self.module("builtins").attr("tuple"), args=[self.sequence(items)])
}

///|
fn Interpreter::index(
  self : Interpreter,
  value : PyValue,
  index : Int32,
) -> PyValue raise {
  value.item(self.literal(Json(index)))
}

///|
fn Interpreter::slice(
  self : Interpreter,
  value : PyValue,
  indices : Array[Int32?],
) -> PyValue raise {
  let all = self.call(self.module("builtins").attr("slice"), args=[
    self.literal(Json::null()),
  ])
  value.item(
    self.tuple(
      indices.map(i => {
        match i {
          Some(i) => self.literal(Json(i))
          None => all
        }
      }),
    ),
  )
}

///|
fn Interpreter::construct(
  self : Interpreter,
  module : String,
  name : String,
  kw : Array[(String, PyValue)],
) -> PyValue raise {
  self.call(self.module(module).attr(name), kw~)
}

///|
fn Scene::array(self : Scene, dtype : String, width : Int32) -> PyValue raise {
  let shape = if width == 1 {
    self.py.literal(Json(self.inputs["num_envs"].int()))
  } else {
    self.py.tuple([self.inputs["num_envs"], self.py.literal(Json(width))])
  }
  self.py.call(self.wp.attr("zeros"), args=[shape], kw=[
    ("dtype", self.wp.attr(dtype)),
    ("device", self.device),
  ])
}

///|
// Pinned Newton's _is_all_graphable returns false when no native actuator path
// is active, including plain implicit actuators. Their actual target/effort
// kernel is ActuatorCollection._implicit_executor, called by write_data_to_sim.
// Only this exact configuration can omit the manager's eager actuator section.
// Post-step callbacks are intentionally retained inside _simulate_physics_only.
fn implicit_capture_proof(
  py : Interpreter,
  robot : PyValue,
  manager : PyValue,
) -> Json raise {
  let collection = robot.attr("actuators")
  let control = collection.attr("_control")
  let groups = collection.attr("_groups")
  let group_names = py.call(py.module("builtins").attr("list"), args=[groups])
  let implicit_type = py.module("isaaclab.actuators").attr("ImplicitActuator")
  let type_fn = py.module("builtins").attr("type")
  let mut exact_implicit = true
  let mut single_joint = true
  for i in 0..<group_names.length() {
    let group = groups.item(py.index(group_names, i))
    if py.call(type_fn, args=[group]).identity() != implicit_type.identity() {
      exact_implicit = false
    }
    if !group.has_attr("num_joints") || group.attr("num_joints").int() != 1 {
      single_joint = false
    }
  }
  let none = py.literal(Json::null())
  let executor = collection.attr("_implicit_executor")
  let executor_present = executor.identity() != none.identity()
  let adapter_present = manager.attr("_adapter").identity() != none.identity()
  let joint_count = collection.attr("num_joints").int()
  let group_count = groups.length()
  let fixed_tendon_count = control.attr("num_fixed_tendons").int()
  let execution_count = collection.attr("_execution_actuators").length()
  let native_group_count = collection.attr("_native_group_names").length()
  let executor_group_count = if executor_present {
    executor.attr("group_names").length()
  } else {
    0
  }
  let native_active = control.attr("native_actuator_path_active").bool()
  let manager_native_active = manager
    .attr("_use_newton_actuators_active")
    .bool()
  let pre_count = manager.attr("_pre_actuator_callbacks").length()
  let post_count = manager.attr("_post_actuator_callbacks").length()
  let data = robot.attr("data")
  let n = robot.attr("num_instances").int()
  let layouts : Array[Json] = []
  for
    (owner, name) in [
      (collection, "_joint_effort_target_sim"),
      (collection, "_joint_pos_target_sim"),
      (collection, "_joint_vel_target_sim"),
      (data, "_sim_bind_joint_effort"),
      (data, "_sim_bind_joint_position_target"),
      (data, "_sim_bind_joint_velocity_target"),
    ] {
    let array = owner.attr(name)
    guard array.is_instance(py.module("warp").attr("array")) &&
      array.attr("dtype").identity() ==
      py.module("warp").attr("float32").identity() &&
      integers(array.attr("shape").json()) == [n, 29] else {
      fail(
        "implicit target kernel needs actual N by 29 float32 Warp arrays: " +
        name,
      )
    }
    layouts.push({
      "name": Json(name),
      "shape": array.attr("shape").json(),
      "strides": array.attr("strides").json(),
      "is_contiguous": array.attr("is_contiguous").json(),
    })
  }
  let joint_map = py.method(robot, "_joint_backend_to_user_map")
  guard joint_map.is_instance(py.module("warp").attr("array")) &&
    joint_map.attr("dtype").identity() ==
    py.module("warp").attr("int32").identity() &&
    integers(joint_map.attr("shape").json()) == [29] &&
    collection.attr("has_implicit_actuators").bool() else {
    fail(
      "implicit target submission requires the real 29-joint backend-to-user map",
    )
  }
  let proof : Json = {
    "joint_count": Json(joint_count),
    "group_count": Json(group_count),
    "all_groups_exact_implicit": Json(exact_implicit),
    "each_group_single_joint": Json(single_joint),
    "fixed_tendon_count": Json(fixed_tendon_count),
    "execution_actuator_count": Json(execution_count),
    "native_group_count": Json(native_group_count),
    "implicit_executor_present": Json(executor_present),
    "implicit_executor_group_count": Json(executor_group_count),
    "native_actuator_path_active": Json(native_active),
    "manager_native_actuator_path_active": Json(manager_native_active),
    "adapter_present": Json(adapter_present),
    "pre_actuator_callback_count": Json(pre_count),
    "post_actuator_callback_count": Json(post_count),
    "post_step_callback_count": Json(
      manager.attr("_post_step_callbacks").length(),
    ),
    "post_step_callbacks_preserved": true,
    "scene_write_data_to_sim_included": false,
    "command_submission": {
      "method": "pinned_implicit_target_kernel",
      "target_kernel": "isaaclab.assets.articulation.ordering_kernels.launch_reorder_joint_targets_user_to_backend",
      "uses_actual_joint_map": true,
      "compute_processed_targets": true,
      "writes_effort_position_velocity": true,
      "writes_native_joint_act": false,
      "coordinate_scatter_preserved": true,
      "external_wrench_logic_preserved": true,
      "dirty_tendon_submission_preserved": true,
      "other_scene_writers_preserved": true,
      "target_view_layouts": Json(layouts),
    },
  }
  guard joint_count == 29 &&
    group_count == 29 &&
    exact_implicit &&
    single_joint &&
    fixed_tendon_count == 0 &&
    execution_count == 0 &&
    native_group_count == 0 &&
    executor_present &&
    executor_group_count == 29 &&
    !native_active &&
    !manager_native_active &&
    !adapter_present &&
    pre_count == 0 &&
    post_count == 0 else {
    fail(
      "SDK non-graphable manager is not the supported pure implicit path: " +
      proof.stringify(),
    )
  }
  proof
}

///|
// Exact pinned Articulation.write_data_to_sim order. Only submit_commands'
// three array.assign calls are replaced by the SDK's own recorded Warp kernel
// using the actual map (the SDK returns _ALL_JOINT_INDICES for identity order).
// No staging clone, SDK method replacement, or manager flag mutation occurs.
fn Scene::write_implicit_robot(self : Scene) -> Unit raise {
  let py = self.py
  let robot = self.robot
  let data = robot.attr("data")
  let instantaneous = robot.attr("_instantaneous_wrench_composer")
  let permanent = robot.attr("_permanent_wrench_composer")
  if instantaneous.attr("active").bool() || permanent.attr("active").bool() {
    let composer = if instantaneous.attr("active").bool() {
      ignore(py.method(instantaneous, "add_raw_buffers_from", args=[permanent]))
      instantaneous
    } else {
      permanent
    }
    let forces = py.method(composer, "get_forces_and_torques")
    let inputs = [
      py.index(forces, 0),
      py.index(forces, 1),
      data.attr("body_link_pose_w").attr("warp"),
    ]
    let kernel = if data.attr("has_body_ordering").bool() {
      inputs.push(py.method(robot, "_body_user_to_backend_map"))
      py
      .module("isaaclab_newton.assets.articulation.kernels")
      .attr("update_wrench_array_with_force_and_torque_ordered")
    } else {
      py
      .module("isaaclab_newton.assets.kernels")
      .attr("update_wrench_array_with_force_and_torque")
    }
    inputs.push(data.attr("_sim_bind_body_external_wrench"))
    inputs.push(robot.attr("_ALL_ENV_MASK"))
    inputs.push(robot.attr("_ALL_BODY_MASK"))
    ignore(
      py.call(self.wp.attr("launch"), args=[kernel], kw=[
        (
          "dim",
          py.tuple([robot.attr("num_instances"), robot.attr("num_bodies")]),
        ),
        ("device", self.device),
        ("inputs", py.sequence(inputs)),
      ]),
    )
  }
  if instantaneous.attr("active").bool() {
    ignore(py.method(instantaneous, "reset"))
  }
  let collection = robot.attr("actuators")
  ignore(
    py.method(collection, "compute", args=[
      py.method(self.manager, "get_physics_dt"),
    ]),
  )
  ignore(
    py.method(
      py.module("isaaclab.assets.articulation.ordering_kernels"),
      "launch_reorder_joint_targets_user_to_backend",
      kw=[
        ("user_effort", collection.attr("_joint_effort_target_sim")),
        ("user_pos_target", collection.attr("_joint_pos_target_sim")),
        ("user_vel_target", collection.attr("_joint_vel_target_sim")),
        ("backend_to_user", py.method(robot, "_joint_backend_to_user_map")),
        ("write_effort", py.literal(true)),
        ("write_pos_target", py.literal(true)),
        ("write_vel_target", py.literal(true)),
        ("write_joint_act", py.literal(false)),
        ("backend_effort", data.attr("_sim_bind_joint_effort")),
        ("backend_pos_target", data.attr("_sim_bind_joint_position_target")),
        ("backend_vel_target", data.attr("_sim_bind_joint_velocity_target")),
        ("backend_joint_act", data.attr("_sim_bind_joint_act")),
        ("device", self.device),
      ],
    ),
  )
  if data.attr("_joint_targets_need_conversion").bool() {
    ignore(
      py.method(
        py.module("isaaclab_newton.assets.articulation.joint_coordinates"),
        "scatter_joint_coordinates",
        args=[
          data.attr("_joint_coord_map"),
          data.attr("_sim_bind_joint_position_target"),
          data.attr("_sim_bind_joint_target_coords"),
          robot.attr("_ALL_ENV_MASK"),
        ],
      ),
    )
  }
  if robot.attr("_fixed_tendon_target_dirty").bool() {
    ignore(
      py.method(robot.attr("_fixed_tendon_control"), "write_data_to_sim", args=[
        py.method(self.manager, "get_control"),
      ]),
    )
    robot.set_attr("_fixed_tendon_target_dirty", py.literal(false))
  }
}

///|
fn Scene::write_scene_commands(self : Scene) -> Unit raise {
  if self.step_method == "_simulate_full" {
    ignore(self.py.method(self.scene, "write_data_to_sim"))
    return
  }
  // Preserve the complete original InteractiveScene writer order and every
  // other scene asset. Only the validated robot uses the equivalent kernel
  // composition above; unsupported copies elsewhere remain explicit failures.
  let mut selected = 0
  for
    name in [
      "_articulations", "_cable_objects", "_deformable_objects", "_rigid_objects",
      "_surface_grippers", "_rigid_object_collections",
    ] {
    let values = self.py.method(self.scene.attr(name), "values").list(self.py)
    for value in values {
      if name == "_articulations" && value.identity() == self.robot.identity() {
        self.write_implicit_robot()
        selected += 1
      } else {
        ignore(self.py.method(value, "write_data_to_sim"))
      }
    }
  }
  guard selected == 1 else {
    fail("validated implicit robot must occur exactly once in the scene writer")
  }
}

///|
fn open_scene(py : Interpreter, config : ExportConfig) -> Scene raise {
  let max_envs = config.profile().limits().max_environments
  guard config.num_envs > 0 &&
    config.num_envs <= max_envs &&
    config.device_id >= 0 else {
    fail(
      "offline reference authoring world count exceeds selected capacity profile",
    )
  }
  let wp = py.module("warp")
  guard wp.attr("__version__").text() == "1.17.0" else {
    fail("offline capture requires Warp 1.17.0")
  }
  let metadata = py.module("importlib.metadata")
  guard py
    .call(metadata.attr("version"), args=[py.literal("mujoco-warp")])
    .text() ==
    "3.15.0" else {
    fail("offline capture requires MuJoCo-Warp 3.15.0")
  }
  // Import the installed upstream launch/config objects. No dynamically executed
  // Python source, replacement solver, or first-party Python module is involved.
  let device = py.literal(Json("cuda:" + config.device_id.to_string()))
  let solver_cfg = py.construct("isaaclab_newton.physics", "MJWarpSolverCfg", [
    ("njmax", py.literal(500)),
    ("nconmax", py.literal(128)),
    ("cone", py.literal("pyramidal")),
    ("integrator", py.literal("implicitfast")),
    ("use_mujoco_contacts", py.literal(true)),
  ])
  let physics = py.construct("isaaclab_newton.physics", "NewtonCfg", [
    ("solver_cfg", solver_cfg),
    ("num_substeps", py.literal(4)),
    // Capture the uncaptured manager operation, never a launch of its old graph.
    ("use_cuda_graph", py.literal(false)),
  ])
  let sim_cfg = py.construct("isaaclab.sim", "SimulationCfg", [
    ("dt", py.literal(0.02)),
    ("device", device),
    ("physics", physics),
  ])
  let launcher = py.call(py.module("isaaclab.app").attr("launch_simulation"), args=[
    sim_cfg,
    py.literal({
      "device": Json("cuda:" + config.device_id.to_string()),
      "visualizer": [],
      "headless": true,
    }),
  ])
  ignore(py.method(launcher, "__enter__"))
  let robot_cls = py.module("isaaclab.assets").attr("ArticulationCfg")
  let actuators = []
  let defaults = []
  let names = @aligned.joint_names()
  let q = @aligned.default_joint_positions()
  for i, name in names {
    let m = @aligned.motor_of(name)
    defaults.push((name, py.literal(Json(q[i]))))
    actuators.push(
      (
        name.replace(old="_joint", new=""),
        py.construct("isaaclab.actuators", "ImplicitActuatorCfg", [
          ("joint_names_expr", py.literal(Json([Json(name)]))),
          ("effort_limit_sim", py.literal(Json(m.effort))),
          ("velocity_limit_sim", py.literal(Json(m.velocity))),
          ("stiffness", py.literal(Json(m.stiffness()))),
          ("damping", py.literal(Json(m.damping()))),
          ("armature", py.literal(Json(m.armature))),
        ]),
      ),
    )
  }
  let spawn = py.construct("isaaclab.sim", "UsdFileCfg", [
    ("usd_path", py.literal(Json(config.usd))),
    ("variants", py.literal(Json(config.usd_variants))),
    ("activate_contact_sensors", py.literal(false)),
    (
      "rigid_props",
      py.construct("isaaclab.sim", "RigidBodyPropertiesCfg", [
        ("disable_gravity", py.literal(false)),
        ("linear_damping", py.literal(0.0)),
        ("angular_damping", py.literal(0.0)),
      ]),
    ),
    (
      "articulation_props",
      py.construct("isaaclab.sim", "ArticulationRootPropertiesCfg", [
        ("enabled_self_collisions", py.literal(Json(config.self_collisions))),
      ]),
    ),
  ])
  let initial = py.call(robot_cls.attr("InitialStateCfg"), kw=[
    ("pos", py.literal([0.0, 0.0, 0.76])),
    ("joint_pos", py.dictionary(defaults)),
    ("joint_vel", py.literal({ ".*": 0.0 })),
  ])
  let robot_cfg = py.call(robot_cls, kw=[
    ("prim_path", py.literal("{ENV_REGEX_NS}/Robot")),
    ("spawn", spawn),
    ("init_state", initial),
    ("soft_joint_pos_limit_factor", py.literal(0.9)),
    ("actuators", py.dictionary(actuators)),
  ])
  let ground = py.construct("isaaclab.assets", "AssetBaseCfg", [
    ("prim_path", py.literal("/World/ground")),
    ("spawn", py.construct("isaaclab.sim", "GroundPlaneCfg", [])),
  ])
  // `type` builds a class object directly. The upstream configclass decorator
  // supplies its real dataclass machinery; it does not parse a source string.
  let base = py.module("isaaclab.scene").attr("InteractiveSceneCfg")
  let klass = py.call(py.module("builtins").attr("type"), args=[
    py.literal("MoonBitAPICSceneCfg"),
    py.tuple([base]),
    py.dictionary([
      ("__module__", py.literal("__main__")),
      ("ground", ground),
      ("robot", robot_cfg),
    ]),
  ])
  let klass = py.call(py.module("isaaclab.utils").attr("configclass"), args=[
    klass,
  ])
  let scene_cfg = py.call(klass, kw=[
    ("num_envs", py.literal(Json(config.num_envs))),
    ("env_spacing", py.literal(0.0)),
    ("replicate_physics", py.literal(true)),
  ])
  let sim = py.call(py.module("isaaclab.sim").attr("SimulationContext"), args=[
    sim_cfg,
  ])
  let scene = py.call(py.module("isaaclab.utils").attr("instantiate"), args=[
    scene_cfg,
  ])
  ignore(py.method(sim, "reset"))
  let robot = scene.item(py.literal("robot"))
  guard robot.attr("joint_names").json() == names.to_json() else {
    fail("USD joint order differs from canonical SDK order")
  }
  let manager = sim.attr("backend_manager")
  let model = py.method(manager, "get_model")
  let solver = manager.attr("_solver")
  let capture_contract : Json = {
    "single_state": manager.attr("_use_single_state").json(),
    "num_substeps": manager.attr("_num_substeps").json(),
    "decimation": manager.attr("_decimation").json(),
    "update_data_interval": solver.attr("update_data_interval").json(),
    "use_mujoco_cpu": solver.attr("use_mujoco_cpu").json(),
    "all_graphable": py.method(manager, "_is_all_graphable").json(),
    "solver_dt": manager.attr("_solver_dt").json(),
  }
  guard manager.attr("_use_single_state").bool() &&
    manager.attr("_num_substeps").int() == 4 &&
    manager.attr("_decimation").int() == 1 &&
    solver.attr("update_data_interval").int() == 1 &&
    !solver.attr("use_mujoco_cpu").bool() else {
    fail(
      "SDK manager does not have the required fixed-step CUDA actuator/solver configuration: " +
      capture_contract.stringify(),
    )
  }
  guard manager.attr("_solver_dt").json() == Json(0.005) else {
    fail("solver dt must be 0.005 seconds")
  }
  let (step_method, all_implicit_capture) = if py
    .method(manager, "_is_all_graphable")
    .bool() {
    ("_simulate_full", Json::null())
  } else {
    ("_simulate_physics_only", implicit_capture_proof(py, robot, manager))
  }
  let result : Scene = {
    py,
    wp,
    launcher,
    sim,
    scene,
    robot,
    manager,
    model,
    solver,
    device,
    targets: py.literal(Json::null()),
    all_worlds: py.literal(Json::null()),
    inputs: { "num_envs": py.literal(Json(config.num_envs)) },
    flags: 0,
    step_method,
    all_implicit_capture,
  }
  let arrays = [
    ("targets", "float32", 29),
    ("reset_pose", "transformf", 1),
    ("reset_velocity", "spatial_vectorf", 1),
    ("reset_joint_position", "float32", 29),
    ("reset_joint_velocity", "float32", 29),
    ("reset_mask", "bool", 1),
  ]
  for (name, dtype, width) in arrays {
    result.inputs[name] = result.array(dtype, width)
  }
  let all_worlds = result.array("bool", 1)
  ignore(py.method(all_worlds, "fill_", args=[py.literal(true)]))
  let flag_type = py.module("newton").attr("ModelFlags")
  let flags = flag_type.attr("SHAPE_PROPERTIES").int() |
    flag_type.attr("BODY_INERTIAL_PROPERTIES").int()
  { ..result, targets: result.inputs["targets"], all_worlds, flags, }
}

///|
fn Scene::force_queries(self : Scene, dt~ : Double = 0.0) -> Unit raise {
  ignore(self.py.method(self.scene, "update", args=[self.py.literal(Json(dt))]))
  let data = self.robot.attr("data")
  ignore(self.py.method(data, "_refresh_user_order_state"))
  for name in ["root_link_pose_w", "root_com_vel_w", "joint_pos", "joint_vel"] {
    ignore(data.attr(name).attr("warp"))
  }
}

///|
// The pinned root mask writers pass ProxyArray outputs straight to wp.launch.
// Warp's ordinary launch accepts their CUDA array interface, but its APIC
// pointer walker needs the actual Warp owners. Use the very same kernels and
// invalidation operations, unwrapping only these output arguments to .warp.
fn Scene::write_root_reset(self : Scene, mask : PyValue) -> Unit raise {
  let py = self.py
  let robot = self.robot
  let data = robot.attr("data")
  let mask = py.method(robot, "_resolve_mask", args=[
    mask,
    robot.attr("_ALL_ENV_MASK"),
  ])
  let kernels = py.module("isaaclab_newton.assets.kernels")
  let pose = self.inputs["reset_pose"]
  ignore(
    py.method(robot, "assert_shape_and_dtype_mask", args=[
      pose,
      py.tuple([mask]),
      self.wp.attr("transformf"),
      py.literal("root_pose"),
    ]),
  )
  let pose_output = data.attr("root_link_pose_w").attr("warp")
  guard pose_output.is_instance(self.wp.attr("array")) else {
    fail("root pose reset requires the real SDK Warp output allocation")
  }
  ignore(
    py.call(
      self.wp.attr("launch"),
      args=[kernels.attr("set_root_link_pose_to_sim_mask")],
      kw=[
        ("dim", py.index(pose.attr("shape"), 0)),
        ("inputs", py.sequence([pose, mask])),
        ("outputs", py.sequence([pose_output])),
        ("device", self.device),
      ],
    ),
  )
  if !robot.attr("root_view").attr("is_floating_base").bool() {
    ignore(
      py.method(self.solver, "notify_model_changed", args=[
        py.module("newton").attr("ModelFlags").attr("JOINT_PROPERTIES"),
      ]),
    )
  }
  ignore(py.method(data, "_reset_pose", kw=[("env_mask", mask)]))
  let velocity = self.inputs["reset_velocity"]
  ignore(
    py.method(robot, "assert_shape_and_dtype_mask", args=[
      velocity,
      py.tuple([mask]),
      self.wp.attr("spatial_vectorf"),
      py.literal("root_velocity"),
    ]),
  )
  let velocity_output = data.attr("root_com_vel_w").attr("warp")
  let acceleration_output = data.attr("body_com_acc_w").attr("warp")
  guard velocity_output.is_instance(self.wp.attr("array")) &&
    acceleration_output.is_instance(self.wp.attr("array")) else {
    fail("root velocity reset requires the real SDK Warp output allocations")
  }
  ignore(
    py.call(
      self.wp.attr("launch"),
      args=[kernels.attr("set_root_com_velocity_to_sim_mask")],
      kw=[
        ("dim", py.index(velocity.attr("shape"), 0)),
        ("inputs", py.sequence([velocity, mask, data.attr("_num_bodies")])),
        ("outputs", py.sequence([velocity_output, acceleration_output])),
        ("device", self.device),
      ],
    ),
  )
  ignore(py.method(data, "_reset_velocity", kw=[("env_mask", mask)]))
}

///|
fn Scene::operation(self : Scene, role : String) -> Unit raise {
  let py = self.py
  match role {
    "step" => {
      ignore(
        py.method(self.robot, "set_joint_position_target_mask", kw=[
          ("target", self.targets),
          ("env_mask", self.all_worlds),
        ]),
      )
      self.write_scene_commands()
      ignore(py.method(self.manager, self.step_method))
    }
    "reset" => {
      let mask = self.inputs["reset_mask"]
      self.write_root_reset(mask)
      for
        (name, keyword, input) in [
          (
            "write_joint_position_to_sim_mask", "position", "reset_joint_position",
          ),
          (
            "write_joint_velocity_to_sim_mask", "velocity", "reset_joint_velocity",
          ),
        ] {
        ignore(
          py.method(self.robot, name, kw=[
            (keyword, self.inputs[input]),
            ("env_mask", mask),
          ]),
        )
      }
      ignore(
        py.method(self.robot, "set_joint_position_target_mask", kw=[
          ("target", self.inputs["reset_joint_position"]),
          ("env_mask", mask),
        ]),
      )
      // The official mask writers populate the N+1 world reset mask. Explicit
      // flags=0 preserves the authored joint state while clearing exactly the
      // selected worlds' qacc_warmstart/qfrc_applied/xfrc_applied/ctrl/act.
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
    }
    "context" => {
      ignore(
        py.method(self.solver, "notify_model_changed", args=[
          py.literal(Json(self.flags)),
        ]),
      )
      ignore(py.method(self.manager, "forward"))
    }
    "refresh" => ignore(py.method(self.manager, "forward"))
    _ => fail("unknown APIC graph role")
  }
  self.force_queries(dt=if role == "step" { 0.02 } else { 0.0 })
}

///|
fn Scene::capture(self : Scene, role : String) -> PyValue raise {
  ignore(
    self.py.call(self.wp.attr("capture_begin"), kw=[
      ("device", self.device),
      ("apic", self.py.literal(true)),
    ]),
  )
  let result = try {
    self.operation(role)
    self.py.call(self.wp.attr("capture_end"), kw=[("device", self.device)])
  } catch {
    error => {
      ignore(
        self.py.call(self.wp.attr("capture_end"), kw=[("device", self.device)]),
      ) catch {
        _ => ()
      }
      fail("APIC graph " + role + ": " + error.to_string())
    }
  }
  guard result.attr("_apic_capture").attr("operation_count").int() > 0 else {
    fail("captured graph contains no APIC operations")
  }
  result
}
