# Native effective-metric helpers

This parallel MoonBit implementation translates actual MuJoCo-Warp 3.15.0
`derivative.py` and `solver.py` effective-force/preconditioner helpers. Original
Python files are preserved. Neither tests nor numerical algorithms, CUDA/NVRTC
compilation, SDK initialization or GPU execution were run for this migration.

`lower(Request)` emits genuine Warp 1.17 by-value array/bounds CUDA ABI, FP32,
one thread per world; the serial per-world order replaces inter-DOF atomics and
does not promise bit parity. `validate_bindings` requires exact positive contiguous
shapes, independent owned allocations and bounded storage. Exact `rhs == res`
views are supported by the three individual copy/block/efm0 helpers. Composite
backbone preconditioning requires a separate original RHS owner.

The 22 real entry points cover:

| Entries | Pinned upstream helpers |
| --- | --- |
| effective-force | `_eff_rhs`, solver `_add_qfrc_smooth_eff` |
| copy-backbone-rhs, block-solve, efm0-solve, zero-sleeping | `_eff_copy_backbone_rhs`, `_eff_block_solve`, `_eff_prec_efm0_solve`, `_zero_sleeping_dofs` |
| build-blocks, factor-blocks, factor-folded-blocks | `_eff_build_blocks_raw`, `_eff_factor_blocks`, `_eff_factor_folded`, `_write_cholesky33` |
| fold-tendon/actuator/efc-sparse/contact-rank1 | actual `_eff_fold_*` rank-one contributions |
| mul-diag, mul-diag-csr, mul-tendon/actuator/contact/fluid | actual `_eff_mul_*` contributions |
| add-qh-diag, add-tendon-qh-diag, add-actuator-qh-diag, add-fluid-qh | `_eff_init_sdiag`, `_eff_add_*_qH*` |

The 3x3 Cholesky uses the **actual upstream MJ_MINVAL pivot floor 1e-15**.
`efm0` solves the actual model sparse lower factor in source reverse/forward
order. Source CSR/row/contact/block descriptors are range-checked before reads;
nonfinite results latch failure. There is no fixed-repeat substitute for a
conditional graph and no fabricated effective inverse.

`preconditioner_plan(PreconditionerPlan)` returns actual native pipeline commands:
optional folded-block construction, masked backbone `sparse_solver.mixed-solve`,
then efm0 or 3x3 solve and sleeping zeroing. The all-3x3 and all-efm0 branches
bypass backbone work exactly as source `eff_prec`. Bind `views["rhs"]` to the
real gradient and `views["res"]` to `ctx_Mgrad`, then use the returned commands
with `newton_solver.plan_with_preconditioner`. `mixed_views` contains genuine
qHLD/qHDiagInv and model metadata, not a dense surrogate inverse. Folded-block
mode includes all source J-D rows; it does not gate them on constraint state.

`backbone_factor_plan(c, include_fluid=...)` performs actual source qH lifecycle:
copy real packed M to distinct qH, add real diagonal/tendon/actuator/fluid terms,
then genuine mixed factorization. It requires unskipped top-level requests.
Physical actuator/passive/fluid/contact/flex coefficients must already exist.

All helpers share one initial-zero `failure:int32[world]` owner with compatible
authenticated sparse-solver stages. Kernels skip a latched failure and atomically
OR errors; no stage clears it. Optional `skip:bool[world]` is the actual CG done
mask. Keep `immutable_parameters()` model owners frozen for the entire graph.
Dynamic contact, J and actuator metadata are checked at each invocation; no D2H
validation is inserted into capture. Publication requires all failure words zero.

`compile_artifact` explicitly invokes the existing MoonBit NVRTC C binding when
the user later runs it. It produces CUBIN and
`moonrobo-native-solver-metrics-module-v1`, pins source/ABI bytes, snapshots supplied
Warp headers, records real compiler flags and checks the native library SHA again
after compilation. External CUDA includes/transitive native dependencies remain
unattested. No compiler operation occurs in lower/check/info/fmt.

Full physical metric coefficient preparation, flex/passive/interpolation
nonassembled products, general `eff_mul_m` closure, performance equivalence,
gradients, runtime and numerical parity remain unverified or external. This is
the real coherent helper/operator layer, not a claim that all `derivative.py` is
translated. Four pending host/source regression definitions are included; none
have run. Source SHA: `derivative.py`
`d2fb5a758e8774ea49546a0d7936534be48cc1f714629239aef71413be670a4a`.
