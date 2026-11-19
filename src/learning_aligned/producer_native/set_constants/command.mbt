///|
/// Compute real supported reference quantities, preserving the original host
/// coordinate input for later restoration. No active solver/GPU state is touched.
pub fn prepare_set_constants(request : CommandRequest) -> Json raise {
  let worlds = request.qpos0.length()
  guard worlds > 0 &&
    worlds <= 64 &&
    (request.models.length() == 1 || request.models.length() == worlds) &&
    request.current_qpos.length() == worlds else {
    raise Invalid(
      "reference host subset requires 1..64 worlds and shared/per-world models",
    )
  }
  let features = request.features
  let counts = [
    features.tendons,
    features.flex,
    features.mocap_bodies,
    features.kinematic_bodies,
    features.equalities,
    features.cameras,
    features.lights,
    features.actuators,
  ]
  guard counts.all(value => value >= 0) else {
    raise Invalid(
      "feature counts must describe nonnegative actual model cardinalities",
    )
  }
  guard features.tendons == 0 &&
    features.flex == 0 &&
    features.mocap_bodies == 0 &&
    features.kinematic_bodies == 0 else {
    raise Unsupported(
      "tendon armature, flex, mocap and locked-kinematic models are outside the rigid host mass/weight subset",
    )
  }
  let layouts = request.models.map(validate_model)
  guard layouts.all(layout => {
    layout.nq == layouts[0].nq && layout.nv == layouts[0].nv
  }) else {
    raise Invalid("world models must share coordinate and DOF cardinality")
  }
  let nq = layouts[0].nq
  guard request.qpos0.all(row => row.length() == nq && row.all(finite)) &&
    request.current_qpos.all(row => row.length() == nq && row.all(finite)) else {
    raise Invalid(
      "current/qpos0 coordinates differ from the complete compiled coordinate layout",
    )
  }
  let reference = @constants.reference_qpos({
    qpos: request.current_qpos,
    qpos0: request.qpos0,
  })
  let results = Array::makei(worlds, fn(world) {
    rigid_reference(
      request.models[world % request.models.length()],
      request.qpos0[world],
    )
  })
  {
    "format": "moonrobo-rigid-host-set-constant-subset-v1",
    "numeric_backend": "CPU/Double",
    "newton_revision": "71eeba16a717d4dcf0b9dd7056a7b6f863054dc3",
    "mujoco_warp_version": "3.15.0",
    "worlds": results.to_json(),
    "saved_qpos": reference.saved().to_json(),
    "reference_qpos": reference.reference().to_json(),
    "restore_qpos_input": reference.restore().to_json(),
    "omitted_feature_counts": features.to_json(),
    "mass_assembly": "rigid-body kinetic-energy Jacobian sum plus authored armature",
    "mass_solve": "moonnum checked dense LU",
    "full_set_const_closure": false,
    "mjwarp_factorization_executed": false,
    "device_state_modified": false,
    "active_solver_transaction": false,
    "runtime_equivalence_verified": false,
  }
}
