# Native Isaac-aligned physics and APIC artifacts

The preserved `isaac_env.py` uses the pinned **kit-less IsaacLab / Newton /
MuJoCo-Warp** backend. It does not use Kit or a PhysX simulation solver. The new
production path preserves that selection: MoonBit owns the environment protocol
and learning loop; C++ loads and launches genuine Warp CUDA APIC graphs. Missing
CUDA, matching Warp, graph files, bindings or hashes are errors. There is no
synthetic physics or Python production fallback.

The retained offline authoring package `producer/` is separate from production. It uses a
limited native CPython object bridge to call the retained vendor SDK objects.
Its orchestration is MoonBit and its launcher is `.mbtx`; it contains no
first-party Python source, `PyRun` or `eval`. The replay library and `gpu_native`
package do not link this bridge or CPython. Producing artifacts is a real SDK/GPU
operation and was **not performed** during migration.

The new [`producer_native`](producer_native/README.md) stages connect MoonBit
directly to MuJoCo, OpenUSD, Warp APIC and NVRTC through C ABIs. Its hybrid path
moves USD preflight and APIC metadata/snapshot/save out of Python while retaining
the genuine SDK scene and kernel capture. It still needs CPython for those SDK
operations. Native module compilation consumes already-generated CUDA source;
it does not implement Warp's Python AST/type-specialization or Newton's complete
solver dispatch. No artifacts have been produced by this path either.

The authoring entry is `cmd/reference_apic_export`, with the
`scripts/export_g1_aligned_apic.mbtx` launcher. Its [README](producer/README.md)
contains the preserved bridge build, legacy configuration and deferred
reference export commands (`export` retains its original semantics). The active
`.mbtx` defaults to `export-native-io`; use its `--python-reference` option for
the old config. New hybrid configuration and native build inputs are in
`producer_native/README.md`. Both producer and reader require explicit `usd_variants`;
the standard native USDA path uses `{}` and does not silently request a missing
vendor variant.

## Public production entry

`gpu_native.load(adapter_library, bundle_manifest, expected_asset_sha256,
self_collisions?, device_id?, expected_manifest_sha256?)` validates the bundle,
loads four graphs and returns `NativeBatch`. `adapter()` provides the actual
`gpu_protocol.BatchAdapter`; `identity()` records library/artifact hashes, SDK
pins and capture contract. `close()` releases the CUDA graphs and context;
GC cleanup is a fallback. Operations use one serialized CUDA stream and return
only after that stream has synchronized.

`cmd` supports `backend: "isaac"` with the same `train`, `evaluate`, `--evaluate`
and weights-only import commands as CPU. Add `--physics-library` and
`--physics-artifact`. The numerical learner still uses `device: "cpu"` and
`amp: "none"`; `physics_device_id` selects the separate CUDA physics device.
`num_envs` must equal the fixed exported batch. `--library` remains the genuine
MuJoCo library used to obtain static kinematics from `--scene`; no MuJoCo CPU
stepping substitutes for the selected CUDA backend.

```text
moon run --target native src/learning_aligned/cmd -- train --library /path/libmujoco.so --scene /path/scene.xml --manifest /path/catalog.json --config /path/isaac-native.json --output /path/checkpoint.json --physics-library /path/libmoonrobo_aligned_apic.so --physics-artifact /path/bundle/manifest.json
```

This is a documented future invocation, not an executed command. Native GPU
checkpoints retain sampling and context state but declare `exact_resume=false`
and `replay_refill_required=true`; restore starts fresh physical episodes and
clears/refills learner replay and history. Evaluations use deterministic resets,
all allocated physical slots and one measured slot. Training allocations are
closed before a separate post-training evaluation allocation is created.

## Real API evidence and pinned build

Warp 1.17 publishes [`wp_apic_load_graph`, `wp_apic_get_param_ptr/size`,
`wp_apic_launch` and `wp_apic_destroy_graph`](https://github.com/NVIDIA/warp/blob/v1.17.0/warp/native/apic.h).
Its [`capture_save` implementation](https://github.com/NVIDIA/warp/blob/v1.17.0/warp/_src/context.py)
registers named **base allocations**, writes graph data and copies compiled
modules into `<graph>_modules`. The native replay source calls these exact APIs;
it is not a newly invented external solver ABI awaiting implementation.

Required pins are Warp `1.17.0` / APIC format `15`, IsaacLab
`46d6cc3d7b115906fad12efd372fbf69f4e3d3ed`, Newton
`71eeba16a717d4dcf0b9dd7056a7b6f863054dc3` and MuJoCo-Warp `3.15.0`.
`native/CMakeLists.txt` enables the real loader with `MOONROBO_WARP_APIC=ON`,
`WARP_NATIVE_INCLUDE_DIR`, `WARP_NATIVE_LIBRARY`, a real CUDA toolkit and matching
MuJoCo include/library paths. Default builds do not pretend to supply CUDA.
Deploy CUDA-enabled Warp and its actual CUDA/NVRTC dependencies: graph loading
can compile internal conditional helpers and is not promised to be JIT-free.

## Bundle v1 wire contract

`gpu_native/manifest.mbt` is the authoritative reader. It rejects changes to the
asset hash, collision mode, canonical 29-joint order, SDK pins, solver settings
or `.02` control time / four `.005` solver steps.

| Field | Meaning |
| --- | --- |
| `format` | `moonrobo.aligned-apic-bundle.v1` |
| `versions` | `warp`, `isaaclab_revision`, `newton_revision`, `mujoco_warp` |
| `num_envs`, `env_origins` | Fixed batch and actual world origins, N by 3 |
| `asset` | `mjcf_sha256`, `usd_sha256`; actual authoring inputs |
| `usd_variants` | Explicit selected variant mapping: `{}` for native standard USDA, or requested real vendor sets, validated during authoring |
| `graphs` | Relative `.wrp` paths named `step`, `reset`, `context`, `refresh` |
| `files` | Unique relative paths and SHA256 of every graph/module/dependency |
| `shared_regions` | `{name, bytes, scalar_type}` for every persistent primitive numeric base allocation, deduplicated by allocation identity |
| `views` | Named `{binding, offset_elements, row_stride_elements, component_stride_elements, width}`; float32 except Boolean `reset_mask` |
| `context_writes` | Robot shape-friction indices per world, world-ground indices, torso COM indices/base per world |
| `solver_cfg` | `njmax=500`, `nconmax=128`, `implicitfast`, `pyramidal`, `use_mujoco_contacts=true` |
| `capture_contract` | Complete physical operation assertions described below, actual broadphase and `update_data_interval=1` |

Component views are `root_pose` (7, xyz/xyzw), `root_com_velocity` (6, world
linear/angular), `root_com_local` (3), `joint_position` / `joint_velocity` (29),
`targets` (29), `reset_pose` (7), `reset_velocity` (6, root-COM world velocity),
`reset_joint_position` / `reset_joint_velocity` (29) and `reset_mask` (1).
Input base allocations must be distinct, per-world and nonoverlapping with
state outputs. Broadcasting output views may use row stride zero. Indexed vendor
views must resolve to this affine map; unsupported layouts are rejected.

Four independent loaded graphs have independently allocated internal state.
The replay copies the **complete persistent numeric union** device-to-device
when changing graph ownership, then writes current inputs and launches on the
same CUDA stream. Pointer/mesh-handle structs and transient CUB workspaces are
never numeric-copy regions. Alias views point at a single canonical binding;
the capacity is that of the base allocation, not the logical slice.

The step graph must set targets, publish `scene.write_data_to_sim()`, and capture
uncaptured manager `_simulate_full()` including
the actual configured actuation path, callbacks, four solver substeps, force clearing and
data publication. Capturing an existing `capture_launch(manager._graph)` is not
equivalent. `includes_actuator_adapter` means that complete configured path:
an adapter is invoked when the real manager owns one; an all-implicit actuator
configuration can legitimately have no separate adapter instance. Single-state
solver operation and update-data interval one are
required. Reset must use vendor mask setters for pose, velocity, joints and
position targets, then clear selected solver warm starts and refresh. Context
must apply both `SHAPE_PROPERTIES` and `BODY_INERTIAL_PROPERTIES`, including
derived solver caches. Merely changing friction/COM buffers is insufficient.
These facts are explicit `capture_contract` fields and the producer must verify
them before writing a successful manifest.

The four branch-free graphs avoid wrapping SAP sort/scan scratch allocation in
a CUDA conditional body. The actual selected broadphase is recorded; NXN must
not be silently assumed. Tier-2 lazy `root_link_vel_w` cannot be bound during
capture. Native gathering instead reads Tier-1 root-COM velocity and computes
`v_link = v_COM - omega cross (R * local_COM)`, subtracts environment origins and
converts xyzw to the aligned wxyz boundary format. Reset performs the inverse
link-to-COM velocity translation before the capture-safe COM setter; the vendor
link-velocity setter itself touches a Tier-2 lazy property and is avoided.

## Checks performed and remaining machine work

The optional offline producer now also offers native USD physics IR/G1 recipes,
13 fixed typed kernel entries, Warp C launch/memory dispatch and single-kernel
APIC capture. `export-native-schedule` moves manager host ordering and copy/clear
into MoonBit while retaining real SDK solver/FK/callbacks and capture registry.
It still uses CPython. The separate single-kernel artifact is not a complete
aligned bundle. See [native producer](producer_native/README.md) and the
[remaining program audit](../../docs/APIC_REMAINING_NATIVE_MIGRATION.md).
The next source layer adds actual rigid-tree builder arrays/FK, host model
constant fragments, four independent collision/sparse CUDA entries and native
CUB/conditional APIs. `export-native-physics-host` moves fixed solver/forward/
context host order into MoonBit while retaining actual SDK physical kernels.
These fragments do not complete model finalization or the full solver. See the
[physics decomposition](../../docs/APIC_PHYSICS_NATIVE_DECOMPOSITION.md).
Further source ports add typed rigid-tree finalization/storage, six primitive
contact pairs, packed-tree LDL/small-block Cholesky, dynamic line search and
completion transitions, and reference mass/inverse-weight calculations.
`export-native-constants-host` migrates complete set-constants host ordering with
real SDK kernels/solves. They remain unexecuted and are not silently wired into
the original GPU solver; see [current scope](../../docs/APIC_FINALIZE_SOLVER_MIGRATION.md).

The subsequent [model/GPU ports](../../docs/APIC_MODEL_GPU_MIGRATION.md) add
resolved primitive shape/contact storage, a seventh CUDA contact pair, a
separate native MuJoCo rigid-collision interface, mixed-factorization baseline,
and an owned multi-kernel GPU program. They remain explicit authoring APIs;
the full aligned four-role artifact and numerical equivalence are not implied.

The next [cooking/device layer](../../docs/APIC_COOKING_DEVICE_MIGRATION.md)
adds real host Mesh/BVH resources, finite schema/equality authoring, GPU GJK,
MathDx native LTO compilation and a genuine multiple-iteration convergence
WHILE. GPU stage outputs have independent execution gates. Full EPA, mixed
CSR/gather GPU factorization and complete physics integration remain deferred;
none of the new execution or GPU compilation entrypoints was run.

- `gpu_protocol`, `gpu_native`, `usd` and `cmd`: native MoonBit typechecking,
  including the nine original Isaac CPU contract test sources and manifest
  refusal cases. No test blocks were executed.
- `gpu_native/apic_loader.c`, `usd/usd_loader.c`: C syntax checks with the real
  installed `moonbit.h`.
- `native/usd_converter.cpp`: C++ syntax check with real installed MuJoCo 3.3.7
  headers. No conversion was executed.
- `native/aot_solver.cpp` and `native/cuda_state.cu`: source written against
  official APIs; **not compiled** because this host has no CUDA SDK or matching
  CUDA-enabled Warp library. No stub headers were used to claim compilation.
- `native/validate_usd.cpp`: source written against OpenUSD; **not compiled**
  because available OpenUSD is an unconfigured source tree without generated
  headers or native libraries. This validator checks structure, not dynamics.
- `producer/` and `cmd/reference_apic_export`: native MoonBit typechecking;
  the isolated authoring C++ bridge was syntax checked with actual CPython 3.12
  headers and its C loader with actual MoonBit headers. No interpreter, SDK,
  export, graph or CUDA operation was run.

Real CUDA build, artifact authoring, graph loading, physics runs, original SDK
parity, numerical differential fixtures and training are all deferred. This
document does not claim successful artifact generation or GPU execution.
