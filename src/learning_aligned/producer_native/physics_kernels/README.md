# Concrete collision and sparse operations

This package implements a finite MoonBit typed CUDA lowerer against the actual
MuJoCo-Warp **3.15.0** source distribution. It connects to the existing native
NVRTC C binding. It also implements the sparse inertia gather-layout builder in
MoonBit. Original upstream implementations remain available for later comparison.

| Operation | Exact source | Implemented behavior |
| --- | --- | --- |
| `mass_gather_layout` | `io.py`, sparse `M_mulm_*` construction inside `put_model` | Convert packed symmetric lower CSR into gather row addresses, columns and original mass-value addresses; mirror off-diagonal references without duplicating mass values |
| `mass-multiply-sparse` | `support.py::mul_m_kernel(check_skip)` | One row per world/DOF; preserve ordered gathers from packed `M`, optional skip gate and float accumulation |
| `constraint-force-zero-sparse` | `solver.py::_zero_qfrc_constraint_sparse` | Zero only unfinished worlds whose constraint state changed |
| `constraint-force-rebuild-sparse` | `solver.py::_update_constraint_init_qfrc_constraint_sparse(compact)` | CSR `Jᵀ force` atomic accumulation, preserving done/state-change/`nefc`/zero-force gates and optional compact DOF remapping |
| `nxn-broadphase` | `collision_driver.py::_nxn_broadphase` and six source helpers | Plane, sphere and original eight-corner AABB filters; model-world batch modulo; missing batched mesh filter; forced explicit pairs; type ordering; global atomic candidate count and output-capacity behavior |

The NXN subset accepts filter bits **0–7**, with sleeping and incremental mode
disabled. OBB, SAP, sleeping/incremental broadphase and unknown operation keys
raise before loading NVRTC. Candidate inputs must already be the upstream
filtered `nxn_geom_pair` / `nxn_pairid` arrays; this is not an implementation of
model-level pair generation. Explicit pair override occurs after filtering, but
the batched missing-mesh gate still runs first. The candidate counter increments
even when the output capacity is exceeded, exactly as in `_add_geom_pair`.

The AABB implementation retains original corner enumeration and floating-point
comparisons, including the `mjMAXVAL` extrema seed. It does not substitute the
mathematically equivalent absolute-rotation shortcut. Collision constants bind
`mjMAXVAL=1e10` and `mjGEOM_MESH=7` from MuJoCo's `mjmodel.h`; the imported constant
references in MuJoCo-Warp's pinned `types.py` are SHA checked and snapshotted.

`lower(Request) -> Lowered` is a pure source-generation API. `Lowered` contains
actual generated CUDA source, source SHA, specialization SHA and exact ordered
entry parameter metadata. The launch ABI uses genuine Warp **1.17.0**
`wp::launch_bounds_t<2>` by value, followed by each declared parameter in order.
Arrays use genuine `wp::array_t<T>` descriptors with byte strides; `coord_mult`
is 1. No array descriptor is synthesized by copying a guessed C layout here.

`compile_specialization(CompileConfig) -> Json` takes this JSON structure:

```json
{
  "request": {
    "nworld": 2, "nv": 35, "ngeom": 40, "npair": 100,
    "njmax": 128, "mass_nnz": 200, "jacobian_capacity": 1024,
    "filter_bits": 7,
    "ngeom_aabb": 1, "ngeom_rbound": 1, "ngeom_margin": 1,
    "ngeom_gap": 1, "ngeom_dataid": 1,
    "check_skip": true, "compact": false,
    "enable_sleep": false, "incremental": false,
    "kernels": ["mass-multiply-sparse", "nxn-broadphase"]
  },
  "mujoco_warp_root": "/sdk/mujoco_warp-3.15.0",
  "warp_native": "/sdk/warp/warp/native",
  "nvrtc_library": "/sdk/cuda/lib64/libnvrtc.so",
  "options": ["--gpu-architecture=compute_90", "--fmad=false"],
  "kind": "ptx",
  "output": "/output/fresh-physics-module"
}
```

All counts above illustrate the schema; callers must supply actual model and
allocation metadata. `mujoco_warp_root` contains `mujoco_warp/_src`. One explicit
matching architecture is required (`compute_...` for PTX, `sm_...` for CUBIN).
C++17 and NVRTC's default device execution space are added if absent, with all
effective options recorded. No fast-math or learning/numerical equivalence is
assumed.

The compile stage SHA checks the complete relevant 3.15 source files, hashes
each selected original factory/kernel/helper definition, and separately hashes
the exact sparse-layout segment in `io.put_model`. Original Python source bytes
are only read and saved with `.source` suffixes. It checks genuine Warp
`builtin.h` and `array.h` identities and snapshots/hash records all supplied
native headers. Other header bytes, external include paths and native compiler
dependencies are distinguished from files attested against the pinned release.
The manifest includes actual compiler/version/options, source/image/log SHAs,
entry signatures and source evidence. It is written last into a fresh directory.

Sparse buffers retain their upstream contracts: inertia `M` is packed
`[nworld,mass_nnz]`, row-address arrays end at their true capacity, gather columns
and mass addresses must be in range, and gather vector/result shapes are
`[nworld,nv]`. Constraint Jacobian values and indices use the original
`[nworld,1,jacobian_capacity]` layout; row metadata and forces use
`[nworld,njmax]`. Compact maps may contain negative inactive indices, which are
skipped, while nonnegative targets must address the output DOF buffer. Clear
constraint forces before rebuilding where the original solver does so; the
atomic rebuild adds to existing values and does not silently clear them.

This is executable source implementation of independent collision/sparse
operations. It does **not** supply sparse factorization/backsubstitution,
constraint construction, contact narrowphase, line search, solver convergence,
full collision/solver closure, complete physics stepping or APIC captures. Their
manifest capability fields remain false. No CPU `mj_step` substitutes for the
GPU solver. Atomic candidate/force ordering and all numerical equivalence await
the deferred comparisons.

Pending test sources cover packed-address preservation, invalid sparse layouts,
actual entry signatures, compact/gating metadata, counter-capacity semantics and
unsupported variants. They were type checked; no tests, CUDA compilation, GPU
launch, model/SDK initialization, artifact export or numerical examples ran.

Source evidence is local `/tmp/mujoco_warp-3.15.0/mujoco_warp/_src` from the
published source distribution. The ported code retains **Copyright 2025 The
Newton Developers**, Apache-2.0; see the original headers and
[Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0).
