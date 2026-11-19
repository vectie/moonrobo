# Native Newton and CG reference iteration

MoonBit generates actual typed CUDA for the MuJoCo-Warp 3.15 solver equations.
The preserved Python implementation is not called by this package. No test,
numerical example, algorithm, SDK, GPU operation or NVRTC compilation was run
during this migration. Numerical equivalence remains pending.

`Request` fixes world/DOF/constraint/contact capacities, dense or CSR Jacobian,
dense or lower-CSR mass, Newton or CG, pyramidal or elliptic cone, warm start,
iteration and line-search limits, and actual generated kernel keys.
`lower` produces source, exact entry descriptors and source/specialization hashes.
There is no placeholder solver ABI.

The generated keys perform these real operations:

- `initialize-controls` resets done, iteration count, search norm and the shared
  active-world counter. It never clears sticky status/overflow, and resets all
  worlds even after an earlier failed graph launch, allowing bounded termination.
- `initialize-state` chooses warm/smooth acceleration, reads authored M plus
  `added_metric`, computes Ma and Jaref, and initializes solver workspaces.
- `constraint-gradient-hessian` evaluates equality/friction/unilateral and actual
  elliptic force/objective/analytic curvature, J-transpose force, gradient and
  Newton H. CG omits H construction.
- `factor-direction` performs actual lower Cholesky and triangular solves in
  owned global scratch: complete H for Newton, explicit preconditioner for CG.
- `line-search` computes actual M/search and J/search products and performs the
  source dynamic Newton bracket, acceptance tests, shifted/rationalized elliptic
  costs, improvement, acceleration/Ma/Jaref updates and line-search overflow.
- `line-search-incremental` additionally emits the source noise-floor exhaustion
  bit used by the real incremental adapter kernels.
- `cg-search-init` applies the source initial gradient gate, actual search and
  previous-gradient state and exactly-once active-world decrement.
- `unconstrained` supplies the actual zero-constraint or zero-DOF copy branch.

`plan(PlanRequest)` returns native launch commands and a true device WHILE whose
last unconditional node is the authenticated convergence producer. Iterations
zero still initialize/evaluate the source initial state, with no WHILE. The
zero-constraint/zero-DOF branch uses only `unconstrained`. Contact capacity zero
is supported for actual noncontact constraints; zero-length views still require
an explicitly owned descriptor rather than an invented pointer.

`plan_with_effective_preconditioner` is the preferred typed link to
`solver_metrics.PreconditionerPlan`, checking live RHS/result/done identity and
matching world/DOF extents. It builds the real operator: mask backbone RHS, actual mixed solve,
efm0/block override and sleep masking. Effective DISCRETE preconditioning is
generally an operator, not the inverse of M plus an arbitrary added matrix.
The simpler `preconditioner_dense` input must represent the actual intended
operator; this package does not manufacture an identity substitute. Native
pipeline authentication, actual operands and backend result gates remain
mandatory for composed programs.

The arithmetic baseline is serial per world with FP32 scalar reductions and
global scratch. It covers the actual equations without claiming the upstream
tile/atomic association or performance. `solver_adapters` supplies optional real
compact gather/scatter and incremental changed-H/cache paths; `source_coverage`
classifies every top-level callable in the fixed solver source. The default plan
uses full reconstruction and retains valid forces for done worlds.

`validate_bindings` proves exact primitive/compound dtype, rank/shape, scalar
alignment, complete strided byte span and writable nonaliasing against actual
owned buffers. `immutable_parameters`/`validate_metadata` validate the actual
frozen CSR, counts, cone groups and numeric model-input snapshots. Sticky status
records invalid domains, nonfinite values or nonpositive factors; no producer
clears it. Native publication must reject nonzero status.

`compile_specialization` uses the existing real C NVRTC interface, hashes and
snapshots pinned primary source and genuine Warp headers, and writes source,
image, compiler log and `moonrobo-native-newton-solver-module-v1` receipt.
`compile_generated` shares that implementation with actual solver adapters.
None of these compiler functions are invoked by static checks or lowering.

Real source-derived input construction remains essential: model dynamics,
constraint/contact generation and effective metric/force programs must provide
coherent actual buffers. A generated iteration body is not a complete model,
scene/step graph or full upstream numerical-equivalence proof. Full upstream
solver closure and runtime equivalence remain false.

Fixed primary source SHA256 values are exported by `primary_sources()`:
MuJoCo-Warp 3.15 `solver.py`, `smooth.py`, `constraint.py`, `math.py`, `types.py`.
`solver.py` is `d26300bbe665aa182a0afc30c3d1ee43c38b8b14841e2e61544c92dea97af916`.
Warp 1.17 `builtin.h` is
`9a8c44dda8453dcee2308ec016a648da43bc77d41427c7694b6555a1f810d7bf`;
`array.h` is `f85ab644afcf70be5b9feb6097fd9ffe4dfe22d5f88948c511609dac60b2d07a`.
Original Apache-2.0 attribution and original source snapshots are preserved.

The text-only `.mbtx` syntax probe imports no solver/lowerer. Extracted genuine
C++ helpers and body expressions passed `clang++ -std=c++17 -fsyntax-only` against
the real Warp headers, including both dense/CSR readers and incremental noise
floor. This is host expression syntax evidence, not CUDA/NVRTC compilation or
runtime validation. Pending regression sources are included and were not run.
