// Copyright 2025 The Newton Developers. SPDX-License-Identifier: Apache-2.0
// Host orchestration adapted from MuJoCo-Warp 3.15.0 set_const.py and pinned
// Newton SolverMuJoCo. Physical kernels remain actual upstream implementations.

///|
fn constant_fields(
  value : PyValue,
  names : Array[String],
) -> Array[PyValue] raise {
  names.map(name => value.attr(name))
}

///|
fn Scene::constant_array(self : Scene, shape : Array[Int32]) -> PyValue raise {
  self.py.call(self.wp.attr("zeros"), args=[self.py.literal(shape.to_json())], kw=[
    ("dtype", self.wp.attr("float32")),
    ("device", self.device),
  ])
}

///|
fn shape0(py : Interpreter, value : PyValue) -> Int32 raise {
  py.index(value.attr("shape"), 0).int()
}

///|
fn Scene::constant_launch(
  self : Scene,
  source : PyValue,
  name : String,
  dimensions : Array[Int32],
  inputs : Array[PyValue],
  outputs : Array[PyValue],
) -> Unit raise {
  ignore(
    self.py.call(self.wp.attr("launch"), args=[source.attr(name)], kw=[
      ("dim", self.py.literal(dimensions.to_json())),
      ("inputs", self.py.sequence(inputs)),
      ("outputs", self.py.sequence(outputs)),
      ("device", self.device),
    ]),
  )
}

///|
/// Explicit bounds on this host port. No unsupported stage is omitted: the
/// actual smooth/tendon/flex/camera/equality/actuator functions are retained.
fn Scene::check_constants_host(
  self : Scene,
  runtime : ScheduledRuntime,
) -> Unit raise {
  self.check_physics_host(runtime)
  let m = self.solver.attr("mjw_model")
  guard m.attr("nv").int() >= 0 &&
    m.attr("nv").int() <= 256 &&
    m.attr("nbody").int() > 0 &&
    m.attr("nbody").int() <= 4096 else {
    fail("constants host mode requires bounded rigid model dimensions")
  }
}

///|
/// Actual fixed-constant host loop: initialize each body, then reverse levels.
fn Scene::set_const_fixed_host(
  self : Scene,
  runtime : ScheduledRuntime,
) -> Unit raise {
  self.check_constants_host(runtime)
  let py = self.py
  let m = self.solver.attr("mjw_model")
  let source = py.module("mujoco_warp._src.set_const")
  let worlds = shape0(py, m.attr("body_subtreemass"))
  self.constant_launch(
    source,
    "_init_subtreemass",
    [worlds, m.attr("nbody").int()],
    [m.attr("body_mass")],
    [m.attr("body_subtreemass")],
  )
  let levels = m.attr("body_tree").list(py)
  for index = levels.length() - 1; index >= 0; index = index - 1 {
    let tree = levels[index]
    self.constant_launch(
      source,
      "_accumulate_subtreemass",
      [worlds, tree.attr("size").int()],
      [m.attr("body_parentid"), m.attr("body_subtreemass"), tree],
      [],
    )
  }
}

///|
/// Shared exact order for reference and restored configurations, including
/// camera/light, flex/tendon, factorization and transmission effects.
fn Scene::constant_smooth_pass(
  self : Scene,
  m : PyValue,
  d : PyValue,
) -> Unit raise {
  let smooth = self.py.module("mujoco_warp._src.smooth")
  for
    name in [
      "kinematics", "com_pos", "camlight", "flex", "tendon", "crb", "tendon_armature",
      "factor_m", "transmission",
    ] {
    ignore(self.py.method(smooth, name, args=[m, d]))
  }
}

///|
/// Complete set_const_0 host sequence with actual SDK kernels/linear solves.
/// This removes Python loop/dispatch logic, not the unported physical backend.
fn Scene::set_const_0_host(
  self : Scene,
  runtime : ScheduledRuntime,
) -> Unit raise {
  self.check_constants_host(runtime)
  let py = self.py
  let m = self.solver.attr("mjw_model")
  let d = self.solver.attr("mjw_data")
  let source = py.module("mujoco_warp._src.set_const")
  let smooth = py.module("mujoco_warp._src.smooth")
  let worlds = d.attr("nworld").int()
  let nv = m.attr("nv").int()
  let nbody = m.attr("nbody").int()
  let ntendon = m.attr("ntendon").int()
  let saved = py.call(self.wp.attr("clone"), args=[d.attr("qpos")])
  self.constant_launch(
    source,
    "_copy_qpos0_to_qpos",
    [worlds, m.attr("nq").int()],
    [m.attr("qpos0")],
    [d.attr("qpos")],
  )
  self.constant_smooth_pass(m, d)
  self.constant_launch(
    source,
    "_compute_meaninertia",
    [shape0(py, m.attr("stat").attr("meaninertia"))],
    constant_fields(m, ["nv", "M_rownnz", "M_rowadr"]) + [d.attr("M")],
    [m.attr("stat").attr("meaninertia")],
  )
  self.constant_launch(
    source,
    "_copy_tendon_length0",
    [shape0(py, m.attr("tendon_length0")), ntendon],
    [d.attr("ten_length")],
    [m.attr("tendon_length0")],
  )
  self.constant_launch(
    source,
    "_compute_eq_data0",
    [shape0(py, m.attr("eq_data")), m.attr("neq").int()],
    constant_fields(m, ["eq_type", "eq_obj1id", "eq_obj2id", "eq_objtype"]) +
    constant_fields(d, ["xpos", "xquat", "xmat"]),
    [m.attr("eq_data")],
  )
  if nv > 0 {
    let unit = self.constant_array([worlds, nv])
    let result = self.constant_array([worlds, nv])
    let diagonal = self.constant_array([worlds, nv])
    for dof in 0..<nv {
      self.constant_launch(
        source,
        "_set_unit_vector",
        [worlds],
        [py.literal(dof.to_json())],
        [unit],
      )
      ignore(py.method(smooth, "solve_m", args=[m, d, result, unit]))
      self.constant_launch(
        source,
        "_extract_dof_A_diag",
        [worlds],
        [py.literal(dof.to_json()), result],
        [diagonal],
      )
    }
    self.constant_launch(
      source,
      "_finalize_dof_invweight0",
      [shape0(py, m.attr("dof_invweight0")), nv],
      constant_fields(m, ["dof_jntid", "jnt_type", "jnt_dofadr"]) + [diagonal],
      [m.attr("dof_invweight0")],
    )
    let row = self.constant_array([worlds, nv])
    let body_result = self.constant_array([worlds, nv])
    let body_diagonal = self.constant_array([worlds, nbody, 6])
    for body in 1..<nbody {
      for component in 0..<6 {
        self.constant_launch(
          source,
          "_compute_body_jac_row",
          [worlds],
          [
            py.literal(nv.to_json()),
            py.literal(body.to_json()),
            py.literal(component.to_json()),
          ] +
          constant_fields(m, [
            "body_parentid", "body_rootid", "body_dofadr", "body_dofnum", "dof_parentid",
          ]) +
          constant_fields(d, ["subtree_com", "xipos", "cdof"]),
          [row],
        )
        ignore(py.method(smooth, "solve_m", args=[m, d, body_result, row]))
        self.constant_launch(
          source,
          "_compute_body_A_diag_entry",
          [worlds],
          [
            py.literal(nv.to_json()),
            py.literal(body.to_json()),
            py.literal(component.to_json()),
            row,
            body_result,
          ],
          [body_diagonal],
        )
      }
    }
    self.constant_launch(
      source,
      "_finalize_body_invweight0",
      [shape0(py, m.attr("body_invweight0")), nbody],
      [m.attr("body_weldid"), body_diagonal],
      [m.attr("body_invweight0")],
    )
  } else {
    self.zero_native(runtime, m.attr("body_invweight0"))
  }
  if ntendon > 0 {
    let jacobian = self.constant_array([worlds, nv])
    let result = self.constant_array([worlds, nv])
    for tendon in 0..<ntendon {
      self.zero_native(runtime, jacobian)
      self.constant_launch(
        source,
        "_copy_tendon_jacobian",
        [worlds],
        [py.literal(tendon.to_json())] +
        constant_fields(m, ["ten_J_rownnz", "ten_J_rowadr", "ten_J_colind"]) +
        [d.attr("ten_J")],
        [jacobian],
      )
      ignore(py.method(smooth, "solve_m", args=[m, d, result, jacobian]))
      self.constant_launch(
        source,
        "_compute_tendon_dot_product",
        [shape0(py, m.attr("tendon_invweight0"))],
        constant_fields(m, ["ten_J_rownnz", "ten_J_rowadr", "ten_J_colind"]) +
        [py.literal(tendon.to_json()), d.attr("ten_J"), result],
        [m.attr("tendon_invweight0")],
      )
    }
  }
  let cam_worlds = ["cam_pos0", "cam_poscom0", "cam_mat0"]
    .map(name => shape0(py, m.attr(name)))
    .fold(init=0, (a, b) => if a > b { a } else { b })
  self.constant_launch(
    source,
    "_compute_cam_pos0",
    [cam_worlds, m.attr("ncam").int()],
    constant_fields(m, ["cam_bodyid", "cam_targetbodyid"]) +
    constant_fields(d, ["cam_xpos", "cam_xmat", "xpos", "subtree_com"]),
    constant_fields(m, ["cam_pos0", "cam_poscom0", "cam_mat0"]),
  )
  let light_worlds = ["light_pos0", "light_poscom0", "light_dir0"]
    .map(name => shape0(py, m.attr(name)))
    .fold(init=0, (a, b) => if a > b { a } else { b })
  self.constant_launch(
    source,
    "_compute_light_pos0",
    [light_worlds, m.attr("nlight").int()],
    constant_fields(m, ["light_bodyid", "light_targetbodyid"]) +
    constant_fields(d, ["light_xpos", "light_xdir", "xpos", "subtree_com"]),
    constant_fields(m, ["light_pos0", "light_poscom0", "light_dir0"]),
  )
  if m.attr("nactuator").int() > 0 && nv > 0 {
    let moment = self.constant_array([worlds, nv])
    let result = self.constant_array([worlds, nv])
    for actuator in 0..<m.attr("nactuator").int() {
      self.constant_launch(
        source,
        "_copy_actuator_moment",
        [worlds],
        [py.literal(actuator.to_json())] +
        constant_fields(d, [
          "moment_rownnz", "moment_rowadr", "moment_colind", "actuator_moment",
        ]),
        [moment],
      )
      ignore(py.method(smooth, "solve_m", args=[m, d, result, moment]))
      self.constant_launch(
        source,
        "_compute_actuator_acc0",
        [shape0(py, m.attr("actuator_acc0"))],
        [py.literal(actuator.to_json()), m.attr("nv"), result],
        [m.attr("actuator_acc0")],
      )
      self.constant_launch(
        source,
        "_resolve_dampratio",
        [shape0(py, m.attr("actuator_biasprm"))],
        constant_fields(m, ["actuator_biastype", "actuator_gainprm"]) +
        [py.literal(actuator.to_json()), m.attr("nv"), moment, result],
        [m.attr("actuator_biasprm")],
      )
    }
  }
  self.copy_native(runtime, d.attr("qpos"), saved)
  self.constant_smooth_pass(m, d)
}

///|
/// Newton's physical statistic pre-pass and locking/state restoration. Native
/// copies require complete matching typed allocations; unsupported layouts fail.
fn Scene::physical_constants_host(
  self : Scene,
  runtime : ScheduledRuntime,
) -> Unit raise {
  self.check_constants_host(runtime)
  let py = self.py
  let solver = self.solver
  let m = solver.attr("mjw_model")
  let d = solver.attr("mjw_data")
  self.copy_native(runtime, solver.attr("_notify_qpos_saved"), d.attr("qpos"))
  self.copy_native(runtime, d.attr("qpos"), m.attr("qpos0"))
  ignore(
    py.method(solver, "_update_body_properties", kw=[
      ("apply_kinematic_armature", py.literal(false)),
    ]),
  )
  for name in ["kinematics", "com_pos", "crb"] {
    ignore(py.method(solver.attr("_mujoco_warp"), name, args=[m, d]))
  }
  if m.attr("ntendon").int() != 0 {
    ignore(py.method(solver.attr("_mujoco_warp"), "tendon", args=[m, d]))
    ignore(
      py.method(py.module("mujoco_warp._src.smooth"), "tendon_armature", args=[
        m, d,
      ]),
    )
  }
  self.constant_launch(
    py.module("newton._src.solvers.mujoco.solver_mujoco"),
    "compute_physical_meaninertia_kernel",
    [d.attr("nworld").int()],
    constant_fields(m, ["nv", "M_rownnz", "M_rowadr"]) + [d.attr("M")],
    [solver.attr("_notify_physical_meaninertia")],
  )
  ignore(
    py.method(solver, "_update_body_properties", kw=[
      ("apply_kinematic_armature", py.literal(true)),
    ]),
  )
  self.copy_native(runtime, d.attr("qpos"), solver.attr("_notify_qpos_saved"))
  self.set_const_0_host(runtime)
  self.copy_native(
    runtime,
    m.attr("stat").attr("meaninertia"),
    solver.attr("_notify_physical_meaninertia"),
  )
}
