///|
fn diagnostic_unavailable(reason : String) -> Json {
  { "available": false, "reason": Json(reason) }
}

///|
// A bounded host read of an actual SDK array, never an inferred shared_N ID.
fn Scene::diagnostic_array(
  self : Scene,
  owner : PyValue,
  name : String,
) -> Json raise {
  if !owner.has_attr(name) {
    return diagnostic_unavailable("attribute absent from pinned SDK object")
  }
  let value = owner.attr(name)
  let value = if value.has_attr("warp") { value.attr("warp") } else { value }
  if !value.is_instance(self.wp.attr("array")) {
    return diagnostic_unavailable("attribute is not a real Warp array")
  }
  let shape = integers(value.attr("shape").json())
  let (_, scalar_bytes) = self.classify(value.attr("dtype"))
  let element_bytes = self.py
    .call(self.py.module("warp._src.types").attr("type_size_in_bytes"), args=[
      value.attr("dtype"),
    ])
    .int()
  let mut count = (element_bytes / scalar_bytes).to_int64()
  for dimension in shape {
    guard dimension >= 0 && dimension <= 4096 else {
      fail("diagnostic array axis exceeds bound")
    }
    count *= dimension.to_int64()
    guard count <= 4096L else { fail("diagnostic array exceeds 4096 scalars") }
  }
  {
    "available": true,
    "attribute": Json(name),
    "dtype": Json(value.attr("dtype").text()),
    "shape": Json(shape),
    "strides_bytes": value.attr("strides").json(),
    "values": self.host(value),
  }
}

///|
fn Scene::diagnostic_commands(self : Scene) -> Json raise {
  let fields : Map[String, Json] = {}
  for
    name in [
      "_joint_effort_target_sim", "_joint_pos_target_sim", "_joint_vel_target_sim",
    ] {
    fields["processed/" + name] = self.diagnostic_array(
      self.robot.attr("actuators"),
      name,
    )
  }
  for
    name in [
      "_sim_bind_joint_effort", "_sim_bind_joint_position_target", "_sim_bind_joint_velocity_target",
      "_sim_bind_joint_target_coords",
    ] {
    fields["backend/" + name] = self.diagnostic_array(
      self.robot.attr("data"),
      name,
    )
  }
  Json(fields)
}

///|
fn Scene::diagnostic_user_commands(self : Scene) -> Json raise {
  let fields : Map[String, Json] = Map([])
  for name in ["_joint_pos_target", "_joint_vel_target", "_joint_effort_target"] {
    fields[name] = self.diagnostic_array(self.robot.attr("actuators"), name)
  }
  Json(fields)
}

///|
fn Scene::diagnostic_inputs(self : Scene) -> Json raise {
  let fields : Map[String, Json] = {}
  for
    name in [
      "targets", "reset_pose", "reset_velocity", "reset_joint_position", "reset_joint_velocity",
    ] {
    fields[name] = self.host(self.inputs[name])
  }
  let mask : Array[Bool] = @json.from_json(self.host(self.inputs["reset_mask"]))
  fields["reset_mask"] = Json(mask.map(x => [if x { 1.0 } else { 0.0 }]))
  Json(fields)
}

///|
fn Scene::diagnostic_solver(self : Scene) -> Json raise {
  if !self.solver.has_attr("mjw_data") {
    return diagnostic_unavailable("solver has no mjw_data")
  }
  let data = self.solver.attr("mjw_data")
  let fields : Map[String, Json] = {}
  for
    name in [
      "nacon", "nefc", "solver_niter", "qacc", "qacc_warmstart", "qfrc_constraint",
      "qpos", "qvel",
    ] {
    fields[name] = self.diagnostic_array(data, name)
  }
  {
    "available": true,
    "boundary": "control-operation; not individual 0.005s substeps",
    "contact_count_scope": "nacon is total detected contacts across worlds",
    "arrays": Json(fields),
  }
}

///|
fn diagnostic_exact_checks(a : Json, b : Json) -> Array[Json] raise {
  let left : Map[String, Json] = @json.from_json(a)
  let right : Map[String, Json] = @json.from_json(b)
  guard left.length() == right.length() else {
    fail("diagnostic field count mismatch")
  }
  let result : Array[Json] = []
  for key, value in left {
    guard right.contains(key) else { fail("diagnostic field absent") }
    result.push({
      "field": Json(key),
      "exactly_equal": Json(value == right[key]),
    })
  }
  result
}

///|
// Diagnostic-only A/B probe. No physics is advanced between writers. The three
// actual control outputs are poisoned so prior original writes cannot hide a
// missing lowered write. Only this validated stateless implicit fixture is
// accepted; other assets, active wrenches and tendon work are rejected.
fn Scene::diagnostic_writer(
  self : Scene,
  views : OracleViews,
  id : String,
  records : Array[Json],
) -> Unit raise {
  let py = self.py
  guard self.step_method == "_simulate_physics_only" &&
    !self.robot.attr("_instantaneous_wrench_composer").attr("active").bool() &&
    !self.robot.attr("_permanent_wrench_composer").attr("active").bool() &&
    !self.robot.attr("_fixed_tendon_target_dirty").bool() else {
    fail(
      "writer diagnostic requires stateless pure implicit control without wrench/tendon side effects",
    )
  }
  guard self.scene.attr("_articulations").length() == 1 else {
    fail("diagnostic requires one articulation")
  }
  for
    name in [
      "_cable_objects", "_deformable_objects", "_rigid_objects", "_surface_grippers",
      "_rigid_object_collections",
    ] {
    guard self.scene.attr(name).length() == 0 else {
      fail("diagnostic refuses other scene writers")
    }
  }
  let before = self.oracle_readback(views)
  let inputs_before = self.diagnostic_inputs()
  let user_before = self.diagnostic_user_commands()
  let solver_before = self.diagnostic_solver()
  ignore(py.method(self.scene, "write_data_to_sim"))
  let original = self.diagnostic_commands()
  let original_physics = self.oracle_readback(views)
  let original_solver = self.diagnostic_solver()
  let user_original = self.diagnostic_user_commands()
  let outputs = [
    "_sim_bind_joint_effort", "_sim_bind_joint_position_target", "_sim_bind_joint_velocity_target",
  ]
  let data = self.robot.attr("data")
  let saved = outputs.map(name => self.host(data.attr(name)))
  let poison : Json = Json(
    Array::makei(2, i => {
      Array::makei(29, j => 32.0 + i.to_double() + j.to_double() / 32.0)
    }),
  )
  let poison_rows = matrix(poison)
  for values in saved {
    let rows = matrix(values)
    guard rows.length() == 2 && rows.all(row => row.length() == 29) else {
      fail("writer diagnostic requires three actual 2x29 control outputs")
    }
    for i in 0..<2 {
      for j in 0..<29 {
        guard rows[i][j] != poison_rows[i][j] else {
          fail("poison must differ from every original output slot")
        }
      }
    }
  }
  for name in outputs {
    self.oracle_assign(data.attr(name), poison)
  }
  let poison_verified = outputs.all(name => self.host(data.attr(name)) == poison)
  // Always restore the original three control arrays, including on failure;
  // this is a control-buffer diagnostic, not a solver checkpoint/restore.
  let attempt : Result[(Json, Json, Json, Json, Json), Error] = try {
    guard poison_verified else { fail("control poison readback mismatch") }
    self.write_scene_commands()
    Ok(
      (
        self.diagnostic_commands(),
        self.oracle_readback(views),
        self.diagnostic_solver(),
        self.diagnostic_inputs(),
        self.diagnostic_user_commands(),
      ),
    )
  } catch {
    error => Err(error)
  }
  for i, name in outputs {
    self.oracle_assign(data.attr(name), saved[i])
  }
  let restored = Array::makei(outputs.length(), i => {
    self.host(data.attr(outputs[i])) == saved[i]
  }).all(x => x)
  let (lowered, lowered_physics, lowered_solver, inputs_after, user_after) = match
    attempt {
    Ok(values) => values
    Err(error) => raise error
  }
  let command_checks = diagnostic_exact_checks(lowered, original)
  let state_unchanged = before == original_physics && before == lowered_physics
  let solver_unchanged = solver_before == original_solver &&
    solver_before == lowered_solver
  let inputs_unchanged = inputs_before == inputs_after
  let user_unchanged = user_before == user_original && user_before == user_after
  let passed = command_checks.all(c => c is { "exactly_equal": true, .. }) &&
    state_unchanged &&
    solver_unchanged &&
    inputs_unchanged &&
    user_unchanged &&
    restored
  records.push({
    "operation": Json(id),
    "passed": Json(passed),
    "strict_implicit_contract": self.all_implicit_capture,
    "no_other_scene_writers": true,
    "no_active_wrench_or_dirty_tendon": true,
    "physics_steps_between_writers": 0,
    "control_poison": poison,
    "poison_readback_verified": Json(poison_verified),
    "poisoned_outputs": Json(outputs),
    "original_outputs_restored": Json(restored),
    "user_commands_before_writers": user_before,
    "original": original,
    "lowered": lowered,
    "exact_command_checks": Json(command_checks),
    "physical_state_unchanged": Json(state_unchanged),
    "solver_arrays_unchanged": Json(solver_unchanged),
    "staging_inputs_unchanged": Json(inputs_unchanged),
    "user_inputs_unchanged": Json(user_unchanged),
  })
  guard passed else {
    fail("original/lowered writer diagnostic differs; physics was not advanced")
  }
}
