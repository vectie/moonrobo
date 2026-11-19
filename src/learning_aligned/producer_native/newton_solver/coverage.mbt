///|
/// Every top-level callable in the fixed solver.py is explicitly classified.
/// Scalar-equivalent arithmetic is not described as tiled association parity.
pub fn source_coverage() -> Json {
  [
    {
      "status": "ported-scalar-equations",
      "implementation": "equations.mbt/line_search.mbt/constraint_source",
      "symbols": [
        "_rescale", "_in_bracket", "_eval_pt_direct_alpha_zero", "_eval_pt_direct",
        "_eval_pt_direct_cost_alpha_zero", "_eval_pt_direct_shifted", "_eval_pt_direct_3alphas",
        "_eval_pt_direct_shifted_3alphas", "_eval_cost", "_eval_pt", "_eval_pt_3alphas",
        "_shift_cost", "_eval_frictionloss_pt", "_eval_frictionloss_cost", "_eval_frictionloss_pt_one",
        "_eval_frictionloss_pt_3alphas", "_eval_elliptic_reference", "_eval_elliptic_alpha_zero",
        "_eval_elliptic_quadratic_cone_gap", "_eval_elliptic_quadratic_shifted",
        "_eval_elliptic_shifted", "_eval_elliptic_middle", "_eval_constraint", "_compute_efc_eval_pt_pyramidal",
        "_compute_efc_eval_pt_elliptic", "_compute_efc_eval_pt_alpha_zero_pyramidal",
        "_compute_efc_eval_pt_alpha_zero_elliptic", "_compute_efc_eval_pt_3alphas_pyramidal",
        "_compute_efc_eval_pt_3alphas_elliptic", "_elliptic_hessian_entry_from_projections",
      ],
    },
    {
      "status": "ported-full-rebuild-reference-gpu",
      "implementation": "kernels.mbt/line_search.mbt",
      "symbols": [
        "_linesearch_iterative_kernel", "_linesearch_iterative", "_linesearch_zero_jv",
        "_linesearch_jv_fused_kernel", "_linesearch", "_solve_init_dof", "_solve_init_jaref_kernel",
        "_solve_init_search_cg_tiled", "_update_constraint_efc", "_zero_qfrc_constraint_sparse",
        "_update_constraint_init_qfrc_constraint_sparse", "_update_constraint_init_qfrc_constraint_dense",
        "_update_constraint", "_update_gradient_zero_grad_dot", "_update_gradient_grad",
        "_update_gradient_grad_tiled", "_update_gradient_init_h_sparse", "_state_check",
        "_active_check", "_update_gradient_JTDAJ_dense_tiled", "_update_gradient_JTCJ_dense",
        "_update_gradient_cholesky", "_update_gradient_cholesky_blocked", "_cholesky_factorize_solve_blocked",
        "_padding_h", "_cholesky_factorize_solve", "_JTDACJ_sparse", "_jtdaj_groups_per_world",
        "_update_gradient", "_mul_m_compact_aware",
      ],
    },
    {
      "status": "ported-device-convergence",
      "implementation": "../device_convergence/lower.mbt fused-finalizers",
      "symbols": [
        "_solve_search_update_cg_tiled", "_solve_beta_finalize_tiled", "_solve_done",
      ],
    },
    {
      "status": "ported-supported-profile-scheduling",
      "implementation": "plan.mbt; zero-constraint kernel; owned fresh initial controls",
      "symbols": [
        "_solver_iteration", "init_context", "solve", "_solve", "_solve_init_efc",
      ],
    },
    {
      "status": "explicit-caller-owned-input-boundary",
      "implementation": "typed model/constraint buffers; added_metric + effective qfrc_smooth",
      "symbols": [
        "_add_qfrc_smooth_eff", "_add_tendon_metric_dense", "_add_actuator_metric_dense",
        "_add_efmK_metric_dense", "_add_flexcon_metric_dense",
      ],
    },
    {
      "status": "ported-optional-incremental-reference-adapters",
      "implementation": "../solver_adapters actual changed-row curvature/cache reuse/recovery; separate authenticated module",
      "symbols": [
        "_qfrc_constraint_from_grad", "_update_gradient_h_incremental", "_update_gradient_h_incremental_sparse",
        "_update_gradient_cholesky_blocked_skip_unchanged", "_update_gradient_incremental",
        "_use_incremental", "_zero_change_counters",
      ],
    },
    {
      "status": "ported-optional-compact-reference-adapters",
      "implementation": "../solver_adapters actual maps/gather/scatter/Mmul and authenticated native solve programs",
      "symbols": [
        "_update_gradient_JTDAJ_dense_tiled_compact", "_init_compact_inertia", "_mul_m_sparse_compact",
        "_sparse_compact", "_gather_M_sparse", "_gather_rhs_compact", "_scatter_solution",
        "smooth_solve_compact", "_gather_dof_vecs_compact", "_scatter_dof_vecs",
        "_gather_J_sparse", "_gather_J_dense", "solve_compact", "_compact_gather",
        "_compact_scatter",
      ],
    },
    {
      "status": "ported-host-owned-context-allocation",
      "implementation": "../solver_adapters/context.mbt; actual storage ownership, not a live SDK context",
      "symbols": ["create_inverse_context", "_create_solver_context"],
    },
  ]
}

///|
pub fn primary_sources() -> Array[(String, String)] {
  [
    (
      "solver.py", "d26300bbe665aa182a0afc30c3d1ee43c38b8b14841e2e61544c92dea97af916",
    ),
    (
      "smooth.py", "6268f0e1b6cb4c9ec6bbd3aa29828dfb36224efb2a3a3e1f54e5f87b6623fdef",
    ),
    (
      "constraint.py", "92e08742228af0929feefd97d4da031454050af8c3cc4ece2df375c7cae5dad6",
    ),
    (
      "math.py", "d08e978993c3d3b5d3f16cb96af94beff519a60a5ea827134b388f30c3a6756c",
    ),
    (
      "types.py", "5ff63b8186bafba2e2d51d5aae84875fb289411d9984f4e06b51813ea088491b",
    ),
  ]
}
