///|
/// Fixed explicit offline operation names; JSON payloads decode to the same
/// public typed APIs. These are actual CPU/Double computations, not a schema
/// plan and not a substitute for complete set_const_0/physics recomputation.
pub fn prepare_constants(request : CommandRequest) -> Json raise {
  let result : Json = match request.operation {
    "body" => update_bodies(@json.from_json(request.parameters)).to_json()
    "subtree-mass" =>
      subtree_masses(@json.from_json(request.parameters)).to_json()
    "mean-inertia" =>
      mean_inertia_from_mass_matrix(@json.from_json(request.parameters)).to_json()
    "pair-properties" =>
      update_pairs(@json.from_json(request.parameters)).to_json()
    "geom-properties" =>
      update_geometries(@json.from_json(request.parameters)).to_json()
    "reference-qpos" => {
      let reference = reference_qpos(@json.from_json(request.parameters))
      {
        "saved_qpos": reference.saved().to_json(),
        "reference_qpos": reference.reference().to_json(),
        "restore_qpos": reference.restore().to_json(),
        "active_solver_state_modified": false,
      }
    }
    _ =>
      raise Unsupported(
        "unknown constant fragment operation: " + request.operation,
      )
  }
  {
    "format": "moonrobo-host-constant-fragment-v1",
    "operation": request.operation.to_json(),
    "result": result,
    "numeric_backend": "CPU/Double",
    "newton_revision": "71eeba16a717d4dcf0b9dd7056a7b6f863054dc3",
    "mujoco_warp_version": "3.15.0",
    "full_set_const_closure": false,
    "device_state_modified": false,
    "runtime_equivalence_verified": false,
  }
}
