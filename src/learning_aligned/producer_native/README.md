# Native APIC producer stages

MoonBit owns configuration, contracts and artifact packaging. Native libraries
are reached through C ABIs; OpenUSD's C++ API uses a small C wrapper. The retained
`../producer` remains byte-for-byte unchanged for later comparisons.
Pinned IsaacLab-derived semantics retain the [upstream notice](UPSTREAM_NOTICE.txt).

The latest [full native translation ledger](../../../docs/APIC_FULL_NATIVE_TRANSLATION.md)
supersedes earlier distance-only and solver-fragment scope below. It adds real
owned cooking/SDF resources, rigid EPA/manifold/plane/heightfield contacts,
mixed sparse LDL and LU tails, Newton/CG iteration, compact/incremental adapters
and effective-metric preconditioners. The preserved producer remains available;
full SDK/model closure and runtime equivalence are still unverified.

| Stage | Implementation | Interpreter required |
| --- | --- | --- |
| MJCF descriptor and MJB | MoonBit → C ABI → MuJoCo | No |
| USD stage/variants | MoonBit → C ABI → Python-disabled OpenUSD | No |
| USD physics IR and fixed G1 recipe | OpenUSD C++ → C ABI → MoonBit scene plan | No |
| Rigid-tree builder arrays / initial FK / world maps | MoonBit + shared MoonNum | No |
| Rigid-tree model/state/control typed host layout and explicit upload | MoonBit → Warp C allocation/upload API when requested | No |
| Resolved primitive shape/contact typed storage | MoonBit → explicit Warp C upload; not complete Newton Model | No |
| Host model-constant fragments | MoonBit CPU/Double + shared MoonNum | No |
| Packed-tree LDL, small-block Cholesky, line search/convergence and rigid reference mass/inverse weights | MoonBit CPU/Double + shared MoonNum | No |
| Existing CUDA source → PTX/CUBIN | MoonBit → NVRTC C API | No |
| 13 fixed typed kernel entries / 11 upstream functions | MoonBit specialization → CUDA → NVRTC | No |
| 4 collision / sparse operation entries and mass gather layout | MoonBit specialization → CUDA → NVRTC; MoonBit CSR mapping | No |
| Six supported primitive narrowphase pairs / material and contact write | MoonBit specialization → CUDA → NVRTC | No |
| Capsule-capsule narrowphase extension | Same typed CUDA/NVRTC path; seven supported pairs in total | No |
| Complex rigid geometry collision from existing MJB | MoonBit → C ABI → explicit MuJoCo CPU library; separate backend | No |
| Mixed compact, tiled-gather and tree factorization baseline | MoonBit CPU/Double; GPU tiled arithmetic still separate | No |
| Triangle Mesh/BVH host cooking and refit | MoonBit → C ABI → actual Warp CPU mesh routines | No |
| Finite authored schema priority and pure equality storage | MoonBit; explicit C upload and later native MJCF compiler input | No |
| GJK simplex/witness and shallow contact stage | MoonBit typed CUDA → NVRTC; EPA cases reject | No |
| Independent MathDx upper tile factor/solve | MoonBit → Warp C LTO/FATBIN and NVRTC/NVJitLink APIs | No |
| Device Newton/CG convergence and multiple-iteration WHILE | MoonBit generated kernels → actual Warp/CUDA conditional APIs | No |
| Rigid GJK/EPA/manifold, plane and heightfield contacts | MoonBit typed CUDA with real full contact writer | No |
| Mixed sparse LDL/solve tail and sparse LU | MoonBit typed cooperative CUDA with actual CSR metadata | No |
| Reference Newton/CG iteration and compact/incremental helpers | MoonBit host plans and typed native Warp entries | No |
| Effective metrics, folded blocks and preconditioner composition | MoonBit typed native entries over actual physical coefficients | No |
| One concrete kernel launch/capture | MoonBit → Warp C ABI | No |
| Owned multi-kernel program with copy/zero and conditional capture | MoonBit → Warp/CUDA C ABI; generated modules and owned buffers | No |
| APIC registration, snapshot and save | MoonBit → C ABI → Warp 1.17 | No |
| Fixed manager ordering and force/mask copy/clear | MoonBit schedule → SDK operations / native Warp memory hooks | SDK portions **yes** |
| Fixed solver / forward / context host ordering | MoonBit → explicitly retained SDK physical stages | SDK portions **yes** |
| Complete G1 Newton model and MuJoCo-Warp physical program | Retained upstream IsaacLab/Newton/MuJoCo-Warp SDK | **Yes** |

The `hybrid` package combines the native stages with actual SDK scene/capture
objects. It does not call Python `capture_save` or Python USD preflight. It still
embeds CPython for the scene, array/type metadata, kernel code generation and
live physics capture. The SDK can itself use Python OpenUSD/NumPy/Torch; moving
one preflight to C++ does not remove those transitive dependencies.

## Explicit entrypoints

These commands are documented for later execution. None was run during the
migration; model compilation, JIT, SDK initialization and exports remain deferred.

```text
moon run --target native cmd/reference_apic_export -- prepare-model MODEL.json
moon run --target native cmd/reference_apic_export -- prepare-scene SCENE.json
moon run --target native cmd/reference_apic_export -- prepare-builder BUILDER.json
moon run --target native cmd/reference_apic_export -- prepare-finalize FINALIZE.json
moon run --target native cmd/reference_apic_export -- prepare-collision-finalize COLLISION_LAYOUT.json
moon run --target native cmd/reference_apic_export -- prepare-constants CONSTANTS.json
moon run --target native cmd/reference_apic_export -- prepare-mass-layout MASS.json
moon run --target native cmd/reference_apic_export -- prepare-factorization FACTOR.json
moon run --target native cmd/reference_apic_export -- prepare-convergence SEARCH.json
moon run --target native cmd/reference_apic_export -- prepare-set-constants REFERENCE.json
moon run --target native cmd/reference_apic_export -- compile-cuda COMPILER.json
moon run --target native cmd/reference_apic_export -- compile-kernels KERNELS.json
moon run --target native cmd/reference_apic_export -- compile-physics-kernels PHYSICS.json
moon run --target native cmd/reference_apic_export -- compile-narrowphase CONTACTS.json
moon run --target native cmd/reference_apic_export -- capture-kernel CAPTURE.json
moon run --target native cmd/reference_apic_export -- collide-native COLLISION.json
moon run --target native cmd/reference_apic_export -- run-gpu-pipeline PIPELINE.json
moon run --target native cmd/reference_apic_export -- prepare-mesh MESH_BYTES.json
moon run --target native cmd/reference_apic_export -- cook-host-mesh HOST_MESH.json
moon run --target native cmd/reference_apic_export -- prepare-schema SCHEMA.json
moon run --target native cmd/reference_apic_export -- prepare-equalities EQUALITIES.json
moon run --target native cmd/reference_apic_export -- compile-convex-gjk GJK.json
moon run --target native cmd/reference_apic_export -- compile-mathdx-tile TILE.json
moon run --target native cmd/reference_apic_export -- compile-device-convergence DEVICE_DONE.json
moon run --target native cmd/reference_apic_export -- export-native-io HYBRID.json
moon run --target native cmd/reference_apic_export -- export-native-schedule SCHEDULED.json
moon run --target native cmd/reference_apic_export -- export-native-physics-host SCHEDULED.json
moon run --target native cmd/reference_apic_export -- export-native-constants-host SCHEDULED.json
moon run --target native cmd/reference_apic_export -- export-reference LEGACY.json
```

`export` remains an alias for `export-reference`, preserving the archived
launcher's actual behavior. The active `scripts/export_g1_aligned_apic.mbtx`
defaults to `export-native-io`; `--python-reference` explicitly chooses the
original producer. `--native-schedule` explicitly selects the new scheduled
hybrid mode. There is no failure-triggered fallback.
`--native-physics-host` additionally selects the explicitly constrained physics
host mode, using the same nested scheduled configuration.

`prepare-model` accepts `model_adapter`, `mujoco_library`, `source_mjcf` and a
fresh `output` path. It writes actual MJB bytes, a compact JSON descriptor whose
exact bytes match the receipt hash, and the receipt. It constructs no Newton
model. See [model](model/README.md) and [compiler](compiler/README.md) for native
build inputs and the complete CUDA compilation request schema.

The subsequent [model/GPU migration](../../../docs/APIC_MODEL_GPU_MIGRATION.md)
documents `prepare-collision-finalize`, `collide-native`, mixed factorization
operations and `run-gpu-pipeline`. Native MuJoCo 3.3.7 collision is a separate
CPU backend. The multi-kernel runner consumes genuine generated modules and
owned initial bytes; it does not construct the missing Newton solver program.
Its initial final-zero WHILE profile remains available. A later genuine device
convergence producer permits multiple iterations with strict initial-count and
unique-writer proofs; it still does not supply missing solver iterations.
Programmatic `host_buffers` / `mixed_factor_buffers`
feed `execute(..., initial_buffers=...)` without numeric conversion or a
temporary file round trip. All these execution commands remain deferred.

The [cooking/device migration](../../../docs/APIC_COOKING_DEVICE_MIGRATION.md)
adds finite authored schema/equality processing, real host Mesh/BVH cooking,
GJK and actual MathDx LTO compilation. The pipeline accepts the registered
module formats with source/ABI/layout checks and separate result gates. Host
mesh IDs are not device resources; GJK output is not a complete contact stream;
independent tiles are not a complete mixed factorization backend. Full USD
composition and full constraint/dynamics integration remain separate boundaries.
EPA/manifold and mixed sparse factorization are now provided by the newer
`convex/contacts` and `sparse_solver` modules; full Newton/CG iteration and
incremental/compact preparation use `newton_solver`, `solver_adapters` and
`solver_metrics`. See the latest ledger for exact source/callable coverage.

The hybrid configuration includes every field of the preserved producer config,
plus five required paths:

```json
{
  "adapter": "/absolute/libmoonrobo_apic_authoring.so",
  "python": "/absolute/sdk/bin/python3.12",
  "site_packages": "/absolute/sdk/lib/python3.12/site-packages",
  "isaaclab_root": "/absolute/IsaacLab",
  "newton_root": "/absolute/newton",
  "usd": "/absolute/g1.usda",
  "usd_variants": {},
  "source_mjcf": "/absolute/g1.xml",
  "output": "/absolute/fresh-apic-bundle",
  "num_envs": 64,
  "device_id": 0,
  "self_collisions": true,
  "model_adapter": "/absolute/libmoonrobo_prepared_model.so",
  "mujoco_library": "/absolute/libmujoco.so",
  "usd_adapter": "/absolute/libmoonrobo_prepared_usd.so",
  "warp_adapter": "/absolute/libmoonrobo_warp_authoring.so",
  "warp_library": "/absolute/sdk/warp/bin/warp.so"
}
```

The writer must load the exact canonical Warp library that owns the SDK's live
capture. Borrowing never calls `wp_init` or takes ownership of the recording,
context or stream. All async file IO precedes borrowing; graph, model and capture
owners remain alive through the final native call. The pinned upstream module
binary is copied with its actual SHA. A genuine `.meta` cache companion is
preserved when present. The native APIC loader uses embedded entry/shared-memory
metadata and actual binary images directly; it does not require that Python
cache file. No synthetic `.meta` is generated.

## Scene, specialization and scheduled hybrid mode

`prepare-scene` accepts `usd_adapter`, `usd`, `usd_variants`, `num_envs`,
`self_collisions` and a fresh `output`. It extracts real composed physics data
and writes the [scene plan](scene/README.md). `native_builder_ready=false` is
deliberate: raw USD schemas do not implement Newton's resolver precedence,
ordering, mesh/inertia processing and device model finalization.

`compile-kernels` uses the [fixed typed lowerer](kernels/README.md), checks actual
pinned IsaacLab source and Warp headers, and delegates compilation to NVRTC.
Its 13 keys cover masked state/target writes, implicit actuation, telemetry,
ordering and publication. The MuJoCo-Warp collision/constraint/sparse solver,
conditional loops and model-constant kernels remain outside this lowerer.

`capture-kernel` uses [native dispatch](dispatch/README.md) and the
[single-kernel runner](capture/README.md) with owned, hashed buffers and real
APIC recording. APIC-only recording executes the launch, so initial buffers are
snapshotted before recording starts. Its separate artifact format contains one
kernel, not the complete aligned four-graph scene/physics closure.

`export-native-schedule` accepts
`{"config": {all hybrid fields above}, "dispatch_adapter": "/absolute/libmoonrobo_warp_dispatch.so"}`.
It consumes the MoonBit scene recipe, compiles a [schedule](schedule/README.md)
from the initialized SDK's actual facts, and lowers every node concretely.
Force staging/restoration, force clearing and reset-mask clearing use actual
Warp copy/memset C hooks, with exact typed owners registered in the SDK capture.
The manager's `_simulate_full` and explicit `forward` host flow move to MoonBit;
actual solver step/reset/model-change, Newton FK, callbacks, actuation, sensors,
publication and Python APIC registry remain SDK calls. SDK publication can
itself invoke guarded manager forward; that behavior is retained.

All captures complete synchronously after borrowing the thread-affine context.
Callback/sensor ordering, adapter identity, scheduling facts, state/model/solver
owners and device context/stream are frozen and checked at operation boundaries.
Unsupported mutations fail. The output includes `scene-plan.json` and
`manager-schedule.json`, explicitly retains `uses_cpython=true`, and makes no
runtime-equivalence assertion. Existing `export-native-io` retains its original
SDK manager operation route, while the reference producer remains byte-identical.

## Builder, collision/sparse, conditional and constant fragments

`prepare-builder` reads a saved native USD receipt with an explicit SHA and
computes real [builder arrays](builder/README.md). Its request is
`{usd_receipt,usd_receipt_sha256,num_envs,self_collisions,placements,output}`.
Each placement is `{position:[x,y,z],quaternion_wxyz:[w,x,y,z]}`; supply one per
environment. The strict rigid-tree subset produces topology, global world
offsets, canonical maps, generalized coordinates, initial FK and optional fully
authored inertia. It does not complete shape cooking, schema resolution,
mass inference, Newton-to-MuJoCo conversion or device finalization.

`prepare-constants` accepts `{request:{operation,parameters},output}` and calls
the actual CPU/Double [constant fragments](constants/README.md): body inertia,
subtree mass, an already assembled matrix's diagonal mean, pair/analytic geom
properties and host reference-coordinate copies. Those copies do not represent
an active GPU transaction; no full `set_const_0` closure is asserted.

`prepare-mass-layout` accepts `{nv,row_adr,row_nnz,col_ind,output}` and constructs
the original symmetric packed-M gather CSR mapping. These three preparation
commands write `input.json`, `result.json` and a receipt hashing the actual
result bytes in a fresh directory. No checks execute the computations.

`compile-physics-kernels` uses [physics_kernels](physics_kernels/README.md): sparse
MVM, gated sparse constraint-force zero/rebuild and a guarded NXN broadphase.
It reuses the genuine NVRTC C API and records source/header/image identities.
These are independent operation ports. Full narrowphase, constraints, sparse
factorization, linesearch/convergence and complete collision/solver capture are
not included; the existing single-G1-kernel runner does not accept this distinct
physics module format.

The [dispatch](dispatch/README.md) package also connects actual Warp CUB scan and
segmented sort, with typed owned buffers and validated immutable host partitions.
Generic dynamic device partitions are outside this safe subset. Genuine
conditional `if/while` capture requires a matching active outer CUDA graph/APIC
recording and supported CUDA capability. Branch construction invokes the callback
once to record its runtime body; it does not replace device convergence with a
fixed repeat. Failed partial graph construction must discard the parent graph.
`Context::capture_graph` constructs that outer graph through the genuine Warp C
API, so bootstrap does not require the Python SDK. The owned `Graph` retains its
allocation/module arena and offers explicit later launch/close operations;
neither capture nor launch is performed by static checks.

`export-native-physics-host` goes beyond the scheduled mode by moving the exact
fixed-profile solver step, forward and shape/inertia notification host order to
MoonBit. It checks imported Newton/MJWarp source SHAs, preserves device and
determinism scopes, callbacks, sensor/energy/RNE stages, state/control conversion,
physical mean-inertia refresh, solref/tendon/connect restoration and successful
step counting. It rejects sleeping/speculative/non-implicitfast/external-contact
profiles. Real collision, constraint solve, implicit integration, constant kernels,
Newton FK and SDK capture metadata still execute through the pinned SDK. New
independent fragments are not silently substituted into this reference path.

All these implementations are source/type checked only. The detailed
[physics decomposition](../../../docs/APIC_PHYSICS_NATIVE_DECOMPOSITION.md)
distinguishes actual computations, native infrastructure and missing closure.

## Further finalize, narrowphase, factorization and set-constants ports

The [finalize](finalize/README.md) package packs actual model/state/control bytes
and offers a separate native `upload`. [narrowphase](narrowphase/README.md)
implements six primitive pairs with material mixing/contact writes and explicit
validation contracts. [factorization](factorization/README.md) computes real
packed-tree sparse LDL and independent small-block Cholesky/solves.
[convergence](convergence/README.md) implements dynamic pyramidal line search
and Newton/CG completion transitions. [set_constants](set_constants/README.md)
assembles a rigid reference mass matrix, Jacobians, inverse weights and composite
inertia using shared MoonNum arithmetic and checked host solves.

Preparation commands accept `{request: package CommandRequest, output: fresh directory}`.
`compile-narrowphase` takes the package's `CompileConfig` directly. No preparation,
compilation or upload was performed during this migration.

`export-native-constants-host` uses the same scheduled config as the previous
host mode; the wrapper selects it only with `--native-constants-host`. It moves
the complete fixed/reference-constant host sequence and physical mean-inertia
pre-pass into MoonBit, retaining actual SDK kernels/solves and APIC metadata.
It checks the imported `set_const.py` SHA and preserves DOF/body/tendon inverse
weights, camera/light references, actuator acceleration/dampratio, locking
armature, qpos and derived-state restoration. Native copy layout guards remain
strict. The mode additionally bounds `nv<=256` and `nbody<=4096`.

These algorithms are not automatically substituted into the live GPU solver.
Full finalization, complex narrowphase, mixed/tiled sparse/Hessian solving,
elliptic search and complete native model/physics capture remain unfinished.
See [current detailed scope and 17-source evidence](../../../docs/APIC_FINALIZE_SOLVER_MIGRATION.md).

The existing dtype/alias checks are followed by shared pure MoonBit contracts:
four operation roles, complete persistent numeric union, transient ownership,
mesh separation, affine component bounds and disjoint physical-context writes.
Native snapshot handling preserves transient size-only semantics and official
mesh relocation. Unknown pointer-bearing buffers fail, rather than becoming
numeric storage. Root asset hashes are bound to native receipts and rechecked
after capture and serialization. The receipts explicitly do not attest the
complete transitive USD/MJCF asset or native-library closure.

The hybrid writes the existing replay bundle format with additional native
receipts and `producer.uses_cpython=true`. `runtime_validated=false` remains
mandatory. Native stage availability is not proof of the complete original
solver/codegen dispatch closure or numerical equivalence.

## Verification status

MoonBit packages/CLI have been typechecked. C loaders and the MuJoCo/Warp C++
sources have syntax-only checks with genuine available headers. This machine
lacks a configured Python-free OpenUSD installation and NVIDIA NVRTC SDK header;
those complete header/build checks are pending. No fake SDK headers were used
as evidence. No tests, library loading, model compilation, CUDA compilation,
capture, export or replay was executed.

See [dependency audit](../../../docs/APIC_PRODUCER_PYTHON_DEPENDENCIES.md)
for the exact remaining Python boundary and immutable source preservation.
The detailed [remaining program audit](../../../docs/APIC_REMAINING_NATIVE_MIGRATION.md)
records source identities and the sparse solver, broadphase, conditional graph,
context-constant and coordinate-mapping work still required.
