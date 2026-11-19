// SPDX-FileCopyrightText: Copyright (c) 2025 The Newton Developers
// SPDX-License-Identifier: Apache-2.0
// Host order adapted from pinned SolverMuJoCo and MuJoCo-Warp 3.15.0.

///|
fn Interpreter::truth(self : Interpreter, value : PyValue) -> Bool raise {
  self.call(self.module("builtins").attr("bool"), args=[value]).bool()
}

///|
/// Both retained context managers only restore state in finally/__exit__.
/// They do not consume exceptions; MoonBit propagates failed operations.
fn Interpreter::exit_physics_scope(
  self : Interpreter,
  scope : PyValue,
) -> Unit raise {
  let none = self.literal(Json::null())
  let result = self.method(scope, "__exit__", args=[none, none, none])
  guard !self.truth(result) else {
    fail("physics scope unexpectedly suppresses errors")
  }
}

///|
/// Pin the actual imported source files, not merely the installed version.
async fn physics_sources(
  py : Interpreter,
  constants_host~ : Bool = false,
) -> Json {
  let files : Array[Json] = []
  let identities = [
    (
      "newton._src.solvers.mujoco.solver_mujoco", "b76ebd67a2f28277b230d72536b2bbf440626ebe7d9d375579102036d8e42e14",
    ),
    (
      "mujoco_warp._src.forward", "f234bfe59134c25726405ccc5078de15d60fe2f3729b1a265d579607ac48a837",
    ),
  ]
  if constants_host {
    identities.push(
      (
        "mujoco_warp._src.set_const", "1a49523e5c6e5c12133dcb54bb7d3b44afa8e11e8477ad96eea8107d62ef608b",
      ),
    )
  }
  for (module_name, expected) in identities {
    let path = @fs.realpath(py.module(module_name).attr("__file__").text())
    guard path.has_suffix(".py") &&
      @artifacts.sha256(@fs.read_file(path).binary()) == expected else {
      fail(
        "physics host orchestration requires actual pinned upstream source: " +
        module_name,
      )
    }
    files.push({
      "module": module_name.to_json(),
      "path": path.to_json(),
      "sha256": expected.to_json(),
    })
  }
  files.to_json()
}

///|
/// Reject unsupported profile changes before dispatching a physics stage.
fn Scene::check_physics_host(
  self : Scene,
  runtime : ScheduledRuntime,
) -> Unit raise {
  self.check_schedule_owners(runtime)
  let solver = self.solver
  let types = self.py.module("mujoco_warp._src.types")
  let option = solver.attr("mjw_model").attr("opt")
  guard !solver.attr("use_mujoco_cpu").bool() &&
    solver.attr("update_data_interval").int() == 1 &&
    !solver.attr("_use_speculative_contacts").bool() &&
    !solver.attr("enable_sleeping").bool() &&
    (
      option.attr("enableflags").int() &
      types.attr("EnableBit").attr("SLEEP").int()
    ) ==
    0 &&
    option.attr("run_collision_detection").bool() &&
    option.attr("integrator").int() ==
    types.attr("IntegratorType").attr("IMPLICITFAST").int() &&
    solver.attr("model").identity() == self.model.identity() else {
    fail(
      "physics host mode requires pinned non-sleeping, non-speculative, internal-contact implicitfast profile",
    )
  }
}

///|
/// Full forward host order for the supported implicitfast/no-sleep profile.
/// Every unmigrated stage calls the real SDK function; no solver is omitted.
fn Scene::mujoco_forward_host(
  self : Scene,
  runtime : ScheduledRuntime,
) -> Unit raise {
  self.check_physics_host(runtime)
  let py = self.py
  let forward_module = py.module("mujoco_warp._src.forward")
  let m = self.solver.attr("mjw_model")
  let d = self.solver.attr("mjw_data")
  let args = [m, d]
  ignore(py.call(forward_module.attr("check_discrete"), args=[m]))
  ignore(
    py.call(forward_module.attr("fwd_position"), args~, kw=[
      ("factorize", py.literal(false)),
    ]),
  )
  self.zero_native(runtime, d.attr("sensordata"))
  ignore(py.method(forward_module.attr("sensor"), "sensor_pos", args~))
  ignore(py.call(forward_module.attr("_energy_pos"), args~))
  ignore(py.call(forward_module.attr("fwd_velocity"), args~))
  ignore(py.method(forward_module.attr("sensor"), "sensor_vel", args~))
  ignore(py.call(forward_module.attr("_energy_vel"), args~))
  let disable = py.module("mujoco_warp._src.types").attr("DisableBit")
  let option = m.attr("opt")
  if (option.attr("disableflags").int() & disable.attr("ACTUATION").int()) == 0 {
    let callback = m.attr("callback").attr("control")
    if py.truth(callback) {
      ignore(py.call(callback, args~))
    }
  }
  self.check_physics_host(runtime)
  ignore(py.call(forward_module.attr("fwd_actuation"), args~))
  ignore(
    py.call(forward_module.attr("fwd_acceleration"), args~, kw=[
      ("factorize", py.literal(true)),
    ]),
  )
  // This remains the real sparse/dense/conditional solve, not a fixed repeat.
  ignore(py.method(forward_module.attr("solver"), "solve", args~))
  if option.attr("run_rne_postconstraint").bool() ||
    (
      (option.attr("disableflags").int() & disable.attr("SENSOR").int()) == 0 &&
      m.attr("sensor_rne_postconstraint").bool()
    ) {
    ignore(
      py.method(forward_module.attr("smooth"), "rne_postconstraint", args~),
    )
  }
  ignore(
    py.method(forward_module.attr("sensor"), "sensor_acc", args~, kw=[
      ("skip_rne_postconstraint", py.literal(true)),
    ]),
  )
}

///|
/// SolverMuJoCo.step host order, with actual generated-kernel options,
/// deterministic scope, force conversion, state conversion and observables.
fn Scene::solver_step_host(
  self : Scene,
  runtime : ScheduledRuntime,
  dt : Double,
) -> Unit raise {
  self.check_physics_host(runtime)
  guard dt == 0.005 else { fail("physics host step requires fixed solver dt") }
  let py = self.py
  let solver = self.solver
  let state = self.manager.attr("backend").attr("state_0")
  let control = self.manager.attr("backend").attr("control")
  let none = py.literal(Json::null())
  ignore(py.method(solver, "validate_observables", args=[none, none]))
  let step = solver.attr("_step").uint64()
  guard step < 2147483647UL else {
    fail("offline physics step counter exceeds supported exact range")
  }
  {
    let device_scope = py.call(self.wp.attr("ScopedDevice"), args=[
      self.model.attr("device"),
    ])
    ignore(py.method(device_scope, "__enter__"))
    defer py.exit_physics_scope(device_scope)
    let execution_scope = py.method(solver, "_scoped_mujoco_warp_execution")
    ignore(py.method(execution_scope, "__enter__"))
    defer py.exit_physics_scope(execution_scope)
    ignore(py.method(solver, "_enable_rne_postconstraint", args=[state, none]))
    ignore(
      py.method(solver, "_apply_mjc_control", args=[
        self.model,
        state,
        control,
        solver.attr("mjw_data"),
      ]),
    )
    ignore(
      py.method(solver, "_update_mjc_data", args=[
        solver.attr("mjw_data"),
        self.model,
        state,
      ]),
    )
    ignore(
      py.method(
        solver.attr("mjw_model").attr("opt").attr("timestep"),
        "fill_",
        args=[py.literal(dt.to_json())],
      ),
    )
    self.mujoco_forward_host(runtime)
    self.check_physics_host(runtime)
    ignore(
      py.method(py.module("mujoco_warp._src.forward"), "implicit", args=[
        solver.attr("mjw_model"),
        solver.attr("mjw_data"),
      ]),
    )
    ignore(
      py.method(
        solver,
        "_update_newton_state",
        args=[self.model, state, solver.attr("mjw_data")],
        kw=[("state_prev", state), ("observables", none)],
      ),
    )
  }
  guard solver.attr("_step").uint64() == step else {
    fail("solver step counter changed during physics host execution")
  }
  solver.set_attr("_step", py.literal((step.to_int() + 1).to_json()))
}

///|
/// Exact SHAPE|BODY_INERTIAL notification host flow. All physical constant
/// kernels are still genuine SDK calls; CPU/Double helpers are separate ports.
fn Scene::notify_model_host(
  self : Scene,
  runtime : ScheduledRuntime,
) -> Unit raise {
  self.check_physics_host(runtime)
  let py = self.py
  let solver = self.solver
  let flag = py.module("newton").attr("ModelFlags")
  guard self.flags ==
    (
      flag.attr("SHAPE_PROPERTIES").int() |
      flag.attr("BODY_INERTIAL_PROPERTIES").int()
    ) else {
    fail(
      "physics host notification requires exactly shape plus inertial properties",
    )
  }
  let execution_scope = py.method(solver, "_scoped_mujoco_warp_execution")
  ignore(py.method(execution_scope, "__enter__"))
  defer py.exit_physics_scope(execution_scope)
  ignore(py.method(solver, "_validate_cone_shape_scales"))
  ignore(py.method(solver, "_update_model_inertial_properties"))
  ignore(py.method(solver, "_invalidate_contact_fast_path"))
  for
    name in [
      "_update_geom_properties", "_update_site_properties", "_update_pair_properties",
    ] {
    ignore(py.method(solver, name))
  }
  ignore(py.method(solver, "_invalidate_contact_fast_path"))
  {
    let device_scope = py.call(self.wp.attr("ScopedDevice"), args=[
      self.model.attr("device"),
    ])
    ignore(py.method(device_scope, "__enter__"))
    defer py.exit_physics_scope(device_scope)
    if runtime.constants_host {
      self.set_const_fixed_host(runtime)
      self.physical_constants_host(runtime)
    } else {
      ignore(
        py.method(solver.attr("_mujoco_warp"), "set_const_fixed", args=[
          solver.attr("mjw_model"),
          solver.attr("mjw_data"),
        ]),
      )
      ignore(py.method(solver, "_set_const_0_with_physical_meaninertia"))
    }
    for name in ["_update_solref_from_invweight0", "_update_tendon_limit_gains"] {
      ignore(py.method(solver, name))
    }
    ignore(
      py.method(solver, "_notify_connect_constraints_changed", args=[
        py.literal(false),
        py.literal(false),
      ]),
    )
  }
  ignore(py.method(solver, "_sync_worldbody_geom_xposes"))
  ignore(py.method(solver, "_sync_site_xposes"))
  // Sleeping is rejected by check_physics_host; no wake operation is dropped.
  self.check_physics_host(runtime)
}
