///|
/// This mode migrates the manager's host control flow and memory operations.
/// Solver kernels, SDK callbacks, FK and publication remain real SDK calls.
/// Host semantics adapted from pinned IsaacLab; see ../UPSTREAM_NOTICE.txt.
pub(all) struct ScheduledExportConfig {
  config : ExportConfig
  dispatch_adapter : String
} derive(FromJson, ToJson)

///|
struct ScheduledRuntime {
  context : @dispatch.Context
  schedule : @schedule.Schedule
  lists : Map[String, Array[PyValue]]
  adapter : PyValue
  observed : Json
  physics_host : Bool
  constants_host : Bool
}

///|
fn Scene::close_schedule(self : Scene) -> Unit raise {
  if self.scheduled is Some(runtime) {
    runtime.context.close()
  }
}

///|
/// Facts and owners on which the fixed schedule was compiled. Recheck before
/// every node as well as at role boundaries: callbacks may mutate manager state.
fn Scene::schedule_observation(self : Scene) -> Json raise {
  let manager = self.manager
  let backend = manager.attr("backend")
  let state = backend.attr("state_0")
  let fields : Map[String, Json] = {}
  for
    name in [
      "_num_substeps", "_solver_dt", "_decimation", "_use_single_state", "_needs_collision_pipeline",
      "_report_contacts",
    ] {
    fields[name] = manager.attr(name).json()
  }
  for
    name in [
      "_staged_body_f", "_world_reset_mask", "_fk_reset_mask", "_contacts", "_solver",
    ] {
    fields[name] = manager.attr(name).identity().to_string().to_json()
  }
  fields["backend_owner"] = backend.identity().to_string().to_json()
  fields["state_owner"] = state.identity().to_string().to_json()
  fields["model_owner"] = self.py
    .method(manager, "get_model")
    .identity()
    .to_string()
    .to_json()
  fields["control_owner"] = backend
    .attr("control")
    .identity()
    .to_string()
    .to_json()
  let device = self.py.call(self.wp.attr("get_device"), args=[self.device])
  fields["device_context"] = device
    .attr("context")
    .uint64()
    .to_string()
    .to_json()
  fields["device_stream"] = device
    .attr("stream")
    .attr("cuda_stream")
    .uint64()
    .to_string()
    .to_json()
  fields["particle_count"] = state.attr("particle_count").json()
  fields["body_count"] = state.attr("body_count").json()
  fields["solver_update_data_interval"] = self.solver
    .attr("update_data_interval")
    .json()
  fields["solver_cpu"] = self.solver.attr("use_mujoco_cpu").json()
  fields["mjw_model_owner"] = self.solver
    .attr("mjw_model")
    .identity()
    .to_string()
    .to_json()
  fields["mjw_data_owner"] = self.solver
    .attr("mjw_data")
    .identity()
    .to_string()
    .to_json()
  fields.to_json()
}

///|
fn Interpreter::present(self : Interpreter, value : PyValue) -> Bool raise {
  // str(WarpArray) can read CUDA data; compare the actual None singleton.
  value.identity() != self.literal(Json::null()).identity()
}

///|
fn manager_lists() -> Array[String] {
  [
    "_pre_actuator_callbacks", "_post_actuator_callbacks", "_state_force_callbacks",
    "_post_step_callbacks", "_newton_imu_sensors",
  ]
}

///|
fn Scene::with_schedule(
  self : Scene,
  adapter : String,
  library : String,
  physics_host~ : Bool = false,
  constants_host~ : Bool = false,
) -> Scene raise {
  let py = self.py
  let manager = self.manager
  let state = manager.attr("backend").attr("state_0")
  let lists : Map[String, Array[PyValue]] = {}
  for name in manager_lists() {
    lists[name] = manager.attr(name).list(py)
  }
  lists["contact_sensors"] = py
    .method(manager.attr("_newton_contact_sensors"), "values")
    .list(py)
  let actuator = manager.attr("_adapter")
  let solver_dt : Double = @json.from_json(manager.attr("_solver_dt").json())
  let substeps = manager.attr("_num_substeps").int()
  let facts : @schedule.ManagerFacts = {
    num_envs: self.inputs["num_envs"].int(),
    num_substeps: substeps,
    solver_dt,
    physics_dt: solver_dt * substeps.to_double(),
    decimation: manager.attr("_decimation").int(),
    single_state: manager.attr("_use_single_state").bool(),
    use_mujoco_contacts: !manager.attr("_needs_collision_pipeline").bool(),
    staged_body_forces: py.present(manager.attr("_staged_body_f")),
    pre_actuator_callbacks: lists["_pre_actuator_callbacks"].length(),
    has_adapter: py.present(actuator),
    post_actuator_callbacks: lists["_post_actuator_callbacks"].length(),
    state_force_callbacks: lists["_state_force_callbacks"].length(),
    post_step_callbacks: lists["_post_step_callbacks"].length(),
    imu_sensors: lists["_newton_imu_sensors"].length(),
    report_contacts: manager.attr("_report_contacts").bool(),
    contact_sensors: lists["contact_sensors"].length(),
    particle_forces: state.attr("particle_count").int() > 0,
  }
  let schedule = @schedule.compile(facts)
  let device = py.call(self.wp.attr("get_device"), args=[self.device])
  let context = @dispatch.Context::borrow(
    adapter,
    library,
    device.attr("context").uint64(),
    device.attr("stream").attr("cuda_stream").uint64(),
    arch=py.method(device, "get_cuda_compile_arch").int(),
  )
  {
    ..self,
    scheduled: Some({
      context,
      schedule,
      lists,
      adapter: actuator,
      observed: self.schedule_observation(),
      physics_host,
      constants_host,
    }),
  }
}

///|
fn Scene::check_schedule_owners(
  self : Scene,
  runtime : ScheduledRuntime,
) -> Unit raise {
  let py = self.py
  guard self.schedule_observation() == runtime.observed else {
    fail(
      "manager facts or state/model/solver owners changed after schedule construction",
    )
  }
  for name in manager_lists() {
    let current = self.manager.attr(name).list(py)
    let expected = runtime.lists[name]
    guard current.length() == expected.length() &&
      Array::makei(current.length(), i => {
        current[i].identity() == expected[i].identity()
      }).all(x => x) else {
      fail(
        "manager callbacks or sensors changed after schedule construction: " +
        name,
      )
    }
  }
  let sensors = py
    .method(self.manager.attr("_newton_contact_sensors"), "values")
    .list(py)
  let expected = runtime.lists["contact_sensors"]
  guard sensors.length() == expected.length() &&
    Array::makei(sensors.length(), i => {
      sensors[i].identity() == expected[i].identity()
    }).all(x => x) &&
    self.manager.attr("_adapter").identity() == runtime.adapter.identity() else {
    fail(
      "manager actuator/contact-sensor owners changed after schedule construction",
    )
  }
}

///|
/// Register actual typed owners in the existing SDK capture registry before
/// the C hook records a memcpy/memset. Addresses never pass through JSON.
fn Scene::native_range(
  self : Scene,
  value : PyValue,
) -> (UInt64, UInt64, UInt64) raise {
  guard value.is_instance(self.wp.attr("array")) &&
    value.attr("is_contiguous").bool() else {
    fail("scheduled native memory operations require contiguous Warp arrays")
  }
  let count = value.attr("size").uint64()
  let (scalar, _) = self.classify(value.attr("dtype"))
  guard scalar == "float32" || scalar == "bool" else {
    fail(
      "scheduled force/mask memory must contain actual float32 or bool elements",
    )
  }
  let width = self.py
    .call(self.py.module("warp._src.types").attr("type_size_in_bytes"), args=[
      value.attr("dtype"),
    ])
    .uint64()
  guard width > 0UL && count <= 2147483647UL / width else {
    fail("scheduled native byte span exceeds exact supported capacity")
  }
  let bytes = count * width
  if bytes == 0UL {
    return (0UL, 0UL, 0UL)
  }
  let base = self.base(value)
  let pointer = value.attr("ptr").uint64()
  guard pointer != 0UL &&
    pointer == base.attr("ptr").uint64() &&
    bytes == base.attr("capacity").uint64() else {
    fail("scheduled force/mask operation must cover its complete actual base")
  }
  let device = self.py.call(self.wp.attr("get_device"), args=[self.device])
  guard value.attr("device").identity() == device.identity() else {
    fail("scheduled native array belongs to another device")
  }
  let capture = self.py.call(
    self.py.module("warp._src.context").attr("_get_apic_capture_for_device"),
    args=[device],
  )
  guard self.py.present(capture) else {
    fail("scheduled native memory requires the active SDK APIC capture")
  }
  ignore(self.py.method(capture, "track_array", args=[value]))
  (pointer, bytes, capture.attr("apic_state").uint64())
}

///|
fn Scene::copy_native(
  self : Scene,
  runtime : ScheduledRuntime,
  destination : PyValue,
  source : PyValue,
) -> Unit raise {
  self.check_schedule_owners(runtime)
  let (dst, bytes, state) = self.native_range(destination)
  let (src, source_bytes, source_state) = self.native_range(source)
  guard bytes == source_bytes &&
    state == source_state &&
    destination.attr("dtype").identity() == source.attr("dtype").identity() &&
    destination.attr("shape").json() == source.attr("shape").json() else {
    fail("scheduled native copy has mismatched owner/type/shape/capture")
  }
  if bytes > 0UL {
    runtime.context.copy_external(dst, src, bytes, capture_state=state)
  }
  ignore(destination.identity())
  ignore(source.identity())
}

///|
fn Scene::zero_native(
  self : Scene,
  runtime : ScheduledRuntime,
  array : PyValue,
) -> Unit raise {
  self.check_schedule_owners(runtime)
  if !self.py.present(array) {
    return
  }
  let (pointer, bytes, state) = self.native_range(array)
  if bytes > 0UL {
    runtime.context.zero_external(pointer, bytes, capture_state=state)
  }
  ignore(array.identity())
}

///|
/// Exact fixed-MJWarp manager.forward host ordering. The real Newton FK
/// delegate is retained; its kernels/dispatch are not substituted by metadata.
fn Scene::forward_scheduled(
  self : Scene,
  runtime : ScheduledRuntime,
) -> Unit raise {
  let py = self.py
  let manager = self.manager
  if !manager.attr("kinematics_dirty").bool() &&
    !manager.attr("transforms_may_change_on_graph_replay").bool() {
    return
  }
  let world = manager.attr("_world_reset_mask")
  let fk = manager.attr("_fk_reset_mask")
  if py.present(world) {
    ignore(
      py.method(
        self.solver,
        "reset",
        args=[manager.attr("backend").attr("state_0")],
        kw=[("world_mask", world), ("flags", py.literal(0))],
      ),
    )
  }
  ignore(py.method(manager, "_eval_fk", args=[world, fk]))
  self.zero_native(runtime, fk)
  self.zero_native(runtime, world)
  manager.set_attr("kinematics_dirty", py.literal(false))
}

///|
/// Concrete lowering of every schedule node. Unmigrated solver operations
/// invoke the real pinned SDK, with no missing-operation or empty-graph fallback.
fn Scene::operation_scheduled(self : Scene, role : String) -> Unit raise {
  guard self.scheduled is Some(runtime) else {
    fail("native schedule runtime is absent")
  }
  let graph_role : @contracts.GraphRole = match role {
    "step" => Step
    "reset" => Reset
    "context" => Context
    "refresh" => Refresh
    _ => fail("unknown manager schedule role")
  }
  self.check_schedule_owners(runtime)
  let py = self.py
  let manager = self.manager
  let backend = manager.attr("backend")
  let state = backend.attr("state_0")
  let none = py.literal(Json::null())
  let mask = self.inputs["reset_mask"]
  let nodes = runtime.schedule.operations(graph_role)
  for index, node in nodes {
    self.check_schedule_owners(runtime)
    guard node.id == index &&
      node.depends_on == (if index == 0 { [] } else { [index - 1] }) else {
      fail("native manager schedule dependency order changed")
    }
    match node.operation {
      SetPositionTarget(reset~) =>
        ignore(
          py.method(self.robot, "set_joint_position_target_mask", kw=[
            (
              "target",
              if reset {
                self.inputs["reset_joint_position"]
              } else {
                self.targets
              },
            ),
            ("env_mask", if reset { mask } else { self.all_worlds }),
          ]),
        )
      WriteSceneData => ignore(py.method(self.scene, "write_data_to_sim"))
      StageBodyForces =>
        self.copy_native(
          runtime,
          manager.attr("_staged_body_f"),
          state.attr("body_f"),
        )
      PreActuatorCallback(i) =>
        ignore(py.call(runtime.lists["_pre_actuator_callbacks"][i]))
      AdapterStep(dt~, swap_state~) =>
        ignore(
          py.method(
            runtime.adapter,
            "step",
            args=[state, backend.attr("control"), py.literal(dt.to_json())],
            kw=[("swap_state", py.literal(swap_state.to_json()))],
          ),
        )
      PostActuatorCallback(i) =>
        ignore(py.call(runtime.lists["_post_actuator_callbacks"][i]))
      RestoreBodyForces(..) =>
        self.copy_native(
          runtime,
          state.attr("body_f"),
          manager.attr("_staged_body_f"),
        )
      StateForceCallback(index=i, ..) =>
        ignore(
          py.call(runtime.lists["_state_force_callbacks"][i], args=[state]),
        )
      Solver(Step(dt~)) =>
        if runtime.physics_host {
          self.solver_step_host(runtime, dt)
        } else {
          ignore(
            py.method(self.solver, "step", args=[
              state,
              state,
              backend.attr("control"),
              none,
              py.literal(dt.to_json()),
            ]),
          )
        }
      Solver(ResetWarmStart(flags~)) =>
        ignore(
          py.method(self.solver, "reset", args=[state], kw=[
            ("world_mask", manager.attr("_world_reset_mask")),
            ("flags", py.literal(flags.to_json())),
          ]),
        )
      Solver(NotifyModelChanged) =>
        if runtime.physics_host {
          self.notify_model_host(runtime)
        } else {
          ignore(
            py.method(self.solver, "notify_model_changed", args=[
              py.literal(self.flags.to_json()),
            ]),
          )
        }
      ClearStateForces(particles~, ..) => {
        if particles {
          self.zero_native(runtime, state.attr("particle_f"))
        }
        if state.attr("body_count").int() > 0 {
          self.zero_native(runtime, state.attr("body_f"))
        }
      }
      PostStepCallback(i) =>
        ignore(py.call(runtime.lists["_post_step_callbacks"][i]))
      ImuSensor(i) =>
        ignore(
          py.method(runtime.lists["_newton_imu_sensors"][i], "update", args=[
            state,
          ]),
        )
      UpdateContacts =>
        ignore(
          py.method(self.solver, "update_contacts", args=[
            manager.attr("_contacts"),
            state,
          ]),
        )
      ContactSensor(i) =>
        ignore(
          py.method(runtime.lists["contact_sensors"][i], "update", args=[
            state,
            manager.attr("_contacts"),
          ]),
        )
      WriteReset(field) => {
        let (method, keyword, input) = match field {
          RootLinkPose =>
            ("write_root_link_pose_to_sim_mask", "root_pose", "reset_pose")
          RootComVelocity =>
            (
              "write_root_com_velocity_to_sim_mask", "root_velocity", "reset_velocity",
            )
          JointPosition =>
            (
              "write_joint_position_to_sim_mask", "position", "reset_joint_position",
            )
          JointVelocity =>
            (
              "write_joint_velocity_to_sim_mask", "velocity", "reset_joint_velocity",
            )
        }
        ignore(
          py.method(self.robot, method, kw=[
            (keyword, self.inputs[input]),
            ("env_mask", mask),
          ]),
        )
      }
      ForwardBoundary => self.forward_scheduled(runtime)
      Publish(dt~) => self.force_queries(dt~)
    }
  }
  self.check_schedule_owners(runtime)
}
