///|
/// Actual source callable coverage; scheduling adapters consume authenticated
/// native programs and never substitute an empty graph for factorization.
pub fn source_coverage() -> Json {
  {
    "source": "mujoco_warp/_src/solver.py",
    "source_sha256": "d26300bbe665aa182a0afc30c3d1ee43c38b8b14841e2e61544c92dea97af916",
    "ported_compact_symbols": [
      "_init_compact_inertia", "_mul_m_sparse_compact", "_gather_M_sparse", "_gather_rhs_compact",
      "_scatter_solution", "smooth_solve_compact", "_gather_dof_vecs_compact", "_scatter_dof_vecs",
      "_gather_J_sparse", "_gather_J_dense", "solve_compact", "_compact_gather",
      "_compact_scatter", "_sparse_compact",
    ],
    "ported_incremental_symbols": [
      "_zero_change_counters", "_update_constraint_efc", "_qfrc_constraint_from_grad",
      "_update_gradient_h_incremental", "_update_gradient_h_incremental_sparse",
      "_update_gradient_cholesky_blocked_skip_unchanged", "_update_gradient_incremental",
      "_padding_h", "_use_incremental",
    ],
    "host_allocation_symbols": [
      "create_inverse_context", "_create_solver_context",
    ],
    "host_active_map_source": {
      "path": "mujoco_warp/_src/island.py",
      "sha256": "af6c95a63a84151b242a9c9760ec98bc4ba8da1be9fcc52a8487fd40ae860e4e",
      "symbols": [
        "_reset_compact_maps", "_compact_dofs_builder", "update_active_dofs",
      ],
      "dynamic_gpu_generation": false,
    },
    "arithmetic_profile": "serial-world-float32; explicit symmetric H scratch normalized from upstream authoritative upper triangle",
    "constraint_profile": "incremental Newton nonelliptic only; compact dense reference solve may use core elliptic kernels",
    "native_factor_backend": "actual supplied MathDx/mixed/dense factor program, authenticated by native pipeline",
    "upstream_tiled_or_atomic_association_preserved": false,
    "full_upstream_solver_closure": false,
    "runtime_equivalence_verified": false,
  }
}

///|
/// Real native NVRTC entry, compiled only when explicitly invoked later.
pub async fn compile_specialization(c : CompileConfig) -> Json {
  let l = lower(c.request)
  let config : @newton_solver.NativeCompileConfig = {
    mujoco_warp_root: c.mujoco_warp_root,
    warp_native: c.warp_native,
    nvrtc_library: c.nvrtc_library,
    options: c.options,
    kind: c.kind,
    output: c.output,
  }
  let module : @newton_solver.NativeModule = {
    format: "moonrobo-native-solver-adapters-module-v1",
    source_name: "solver_adapters.cu",
    request: c.request.to_json(),
    source: l.source,
    source_sha256: l.source_sha256,
    specialization_sha256: l.specialization_sha256,
    entries: l.entries.to_json(),
    launch_policy: l.launch_policy.to_json(),
    coverage: source_coverage(),
  }
  @newton_solver.compile_generated(config, module)
}
