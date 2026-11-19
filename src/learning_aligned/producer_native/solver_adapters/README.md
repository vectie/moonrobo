# Actual compact and incremental solver adapters

This optional MoonBit lowerer ports real MuJoCo-Warp 3.15 compact and incremental
solver arithmetic. Original Python implementations are preserved. No test,
numerical algorithm/example, GPU, SDK or NVRTC compilation was executed.

`lower(Request)` generates typed CUDA entries for padded inertia initialization,
actual lower-CSR mass gather, RHS/vector gather, solution/vector scatter, dense
or CSR Jacobian gather, compact/full symmetric mass multiplication, incremental
state/force change tracking, J-transpose force rebuild, stable gradient scaling,
changed-row Hessian updates, cached Cholesky reuse/refactor and real direction
solve, final force recovery and padded Hessian diagonal initialization.
`incremental-initialize` sets real initial grad-scale/cache state; the per-loop
zero-changes kernel only resets the two change counts. Every entry preserves
the sticky `status` world latch and skips worlds with an existing failure.

Incremental mode is the actual source Newton/nonelliptic profile. A quadratic
state flip records the actual row, and H receives plus/minus D times the actual
Jacobian row outer product. Stable unchanged worlds retain search/factor and
track the original scalar gradient ratio. Changed curvature triggers actual
Cholesky factorization; unchanged curvature reuses the real factor. The source
authoritative upper triangle is normalized to explicit symmetric H storage.
Serial-world FP32 arithmetic differs from upstream atomics/tiles; numerical
parity is unverified. Elliptic constraints use the core full-rebuild path.

Bindings require exact shapes/dtypes and owned-byte proof, including writable
self/cross-parameter nonaliasing. `immutable_parameters(request,key)` and
`validate_metadata(request,key,snapshots)` operate on each actual entry's subset
of operands. Real inverse compact maps, active prefixes, padded negative indices,
mass/Jacobian CSR addresses/unique columns and nonelliptic partitions are checked.
Dynamic changed counts/IDs are bounded on the GPU before every indexed read.
No inferred/fake map, pointer or empty factor graph is accepted.

`compact_smooth_plan(CompactPlan)` builds actual inertia init, mass gather, RHS
gather, caller-supplied authenticated native factor/solve and solution scatter.
`compact_constraint_plan` builds actual M/J/vector gather, a genuine supplied
native solver program, vector scatter and full-coordinate Ma refresh. The latter
requires the refresh input to be the actual scattered acceleration. MathDx and
mixed solver programs remain responsible for their own real factor/status
gates; a program array alone is not an operator-equivalence proof.

`incremental_plan(IncrementalPlan)` composes the actual core initialization and
full H/factor once, resets incremental state, then uses the real device WHILE:
incremental line search, zero counters, force/state tracking, force rebuild,
gradient scale/rebuild, H delta, cached factor/direction, and the unconditional
bounded source convergence tail. Final qfrc recovery includes done worlds.
Core/adapter shared state views must be exactly the same actual descriptors.
The native pipeline enforces cross-entry order and the sticky shared status.
Compact incremental plans include all four real gathers before initialization
and scatter/full-Ma refresh after recovery, binding core M/J/vector inputs to
those actual outputs. `effective_cg_plan(EffectiveCGPlan)` supplies the preferred
typed linkage of core CG state to the actual effective-preconditioner program.

`allocate_solver_context` and `allocate_inverse_context` create real host-owned
byte arrays matching upstream workspace optional shapes, including empty arrays.
Source `empty` storage is deterministically zeroed on the host and explicitly
marked as requiring the actual initialization kernels; this is not a live GPU
SolverContext or APIC transaction. `native_control_buffers` supplies initial
canonical control bytes and the serial backend's additional factor scratch.

`build_active_maps(ActiveMapRequest)` actually ports pinned `island.py` reset and
tree-order awake==1 packing on the host, returning ncdof/maps/overflow bytes.
It preserves previous overflow and ORs NVMAX=128 when active capacity is exceeded.
These are imported immutable initial inputs. It does not implement dynamic GPU
sleep/active-set regeneration inside a replay graph, and capped maps still need
an overflow publication gate.

`compile_specialization` uses the real shared C NVRTC compilation/evidence path
and writes source/header/primary snapshots, image and a
`moonrobo-native-solver-adapters-module-v1` receipt. Its source-only lowerer and
validators never invoke it. Full model construction, all upstream solver branches,
and numerical execution equivalence remain explicit external boundaries.

Primary sources: MuJoCo-Warp 3.15 `solver.py` SHA256
`d26300bbe665aa182a0afc30c3d1ee43c38b8b14841e2e61544c92dea97af916`,
and `island.py` SHA256
`af6c95a63a84151b242a9c9760ec98bc4ba8da1be9fcc52a8487fd40ae860e4e`.
`source_coverage()` records exact solver symbols and representation differences.
Apache-2.0 attribution is retained. Genuine Warp 1.17 helper/body expression
syntax passed a text-only `.mbtx` extraction and real-header Clang syntax check;
this does not claim full CUDA compilation. Pending tests were only typechecked.
