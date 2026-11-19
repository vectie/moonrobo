# Offline authoring for the native G1 APIC adapter

This package supplies a MoonBit build-time producer for four genuine upstream
IsaacLab/Newton/MuJoCo-Warp APIC graphs. The production adapter in
`../gpu_native` loads their saved Warp operations with the native Warp C API.
It does not link this package, CPython, Torch, or an installed Python SDK.

The genuine N2 four-graph export and bounded native replay/learner gates have
executed on the pinned Spark SDK. Retained independent SDK comparisons still
contain numerical failures; see the [execution record](../../../docs/DGX_SPARK_APIC_EXPORT_PLAN.md).
The N4/N8 extension below is prepared for separate bounded validation, not yet
GPU-verified. Every newly authored manifest keeps `runtime_validated=false`;
successful authoring is not a physical-equivalence result.

## Build-time dependencies

- CPython 3.12 headers and embedding library matching the pinned kit-less SDK.
- IsaacLab checkout `46d6cc3d7b115906fad12efd372fbf69f4e3d3ed` and Newton checkout
  `71eeba16a717d4dcf0b9dd7056a7b6f863054dc3`, with clean tracked source trees.
- Warp 1.17.0, MuJoCo-Warp 3.15.0, the SDK's matching MuJoCo/NumPy/Torch/OpenUSD
  dependencies, CUDA GPU/driver, and the original converted G1 USD assets.
- MoonBit native toolchain, C++17 compiler and CMake 3.24 or newer.

Build the optional authoring bridge later on that SDK machine:

```sh
cmake -S src/learning_aligned/producer/native -B target/apic-authoring \
  -DPython3_ROOT_DIR=/absolute/pinned/sdk/python-prefix
cmake --build target/apic-authoring --config Release
```

On Linux the result is `libmoonrobo_apic_authoring.so`; on macOS it is a `.dylib`.
The bridge is loaded explicitly with `RTLD_NOW|RTLD_GLOBAL` so official CPython
extension modules can resolve embedding symbols. Interpreter/library ownership
lasts for the process because upstream CUDA pools, threads and native finalizers
can outlive individual object wrappers. The process rejects a second interpreter
or site-packages configuration and rejects retries after partial initialization.

The bridge exposes only object import, literal JSON construction, reference-safe
attribute/item access, calls, type/identity/length queries, and text conversion.
It contains no `PyRun`, `eval`, `exec`, source-string kernels, Python subprocess,
or first-party Python implementation of the solver. The scene class is created
with the standard `type` object and upstream `configclass`, without source text.
Returned embedded NUL text and oversized byte sequences fail explicitly.

## Explicit authoring command

Create a configuration JSON containing all fields below. Paths should be
absolute; the output directory must not already exist.

```json
{
  "adapter": "/absolute/target/apic-authoring/libmoonrobo_apic_authoring.so",
  "python": "/absolute/pinned/sdk/bin/python3.12",
  "site_packages": "/absolute/pinned/sdk/lib/python3.12/site-packages",
  "isaaclab_root": "/absolute/IsaacLab",
  "newton_root": "/absolute/newton",
  "usd": "/absolute/g1_29dof.usda",
  "usd_variants": {},
  "source_mjcf": "/absolute/g1_29dof.xml",
  "output": "/absolute/fresh/g1-batch64-apic",
  "num_envs": 64,
  "device_id": 0,
  "self_collisions": true
}
```

Then, **when the GPU is available**, explicitly run either entry point:

```sh
moon run --target native cmd/reference_apic_export -- export /absolute/export.json
moon run scripts/export_g1_aligned_apic.mbtx /absolute/moonrobo /absolute/export.json --python-reference
```

The `.mbtx` is only a launcher for the ordinary workspace command; it does not
import unpublished local packages. The authoring command checks the actual git
HEAD and both staged/unstaged tracked changes with git itself, including linked
worktrees, and verifies canonical imported `isaaclab`, `isaaclab_newton`, and
`newton` files reside in those source trees. It checks actual Warp/MuJoCo-Warp
versions, actual joint order/default pose, single-state GPU stepping, graph-safe
actuators, four 0.005-second substeps and `update_data_interval == 1`.
`usd_variants` is required and recorded in the manifest: use `{}` for a native
converted USD, or `{"Physics":"mujoco"}` for the original vendor USD when that
variant exists. The actual OpenUSD default prim is inspected and every requested
variant set/selection is checked, since the upstream spawner otherwise only
warns when a variant set is missing.

`asset.usd_sha256` hashes the actual USD entry file. `asset.mjcf_sha256` and
`asset.source_mjcf_sha256` hash the original compiled MJCF used by the native
CLI for kinematic identity; they are not the USD hash. Adjacent USD references
are loaded by the SDK during authoring; the graph's serialized mesh data, graph
files, module binaries and metadata receive their own SHA256 inventory. Changing
the source USD tree requires producing a fresh artifact and later verification.

## Captured operations and memory contract

- **step:** real masked full-batch joint targets and explicit Tier-1 state
  publication. The graphable SDK path uses the original scene writer and
  `_simulate_full`. The separately proven all-implicit path uses the pinned
  implicit target kernel (including its real identity/permutation map) for
  strided control copies and `_simulate_physics_only`; all other scene writers
  and post-step callbacks are preserved. The manifest records the selected
  path and its strict actuator contract. No manager flag is forced.
- **reset:** full-N dedicated input arrays and a real bool N mask, official root
  pose, root **COM** velocity, joint position/velocity and target mask writers;
  actual `SolverMuJoCo.reset(state, world_mask, flags=0)`, manager forward/FK and
  Tier-1 publication. The N+1 manager world mask selects precisely the written
  worlds. `flags=0` preserves authored q/qd while clearing qacc warm starts,
  applied generalized/body forces, activation and control buffers. Native input
  conversion computes `v_com = v_link + omega cross (R * com_local)`; the unsafe
  lazy SDK root-link velocity property is never captured.
- **context:** native writes target the actual primitive model friction and
  torso COM bases; the graph performs full upstream
  `notify_model_changed(SHAPE_PROPERTIES | BODY_INERTIAL_PROPERTIES)`, forward
  and publication. Derived inertia/contact constants are not approximated.
- **refresh:** genuine manager forward and publication, without advancing time.

Four branch-free graphs avoid wrapping MuJoCo's SAP scratch work in an outer
CUDA conditional. Each named component records the real base allocation,
scalar offset, row stride and component stride; bounds and shapes are checked.
Gathered/non-affine property views that cannot refer to the actual model base
are rejected, rather than writing a staging copy. Every reset/target input has
its own full-N allocation; unselected state slots are never padded/reset.

The producer uses the pinned official APIC typed region registry to collect the
union of all recorded non-transient numeric base allocations across the four
operations, plus explicit state/input/property views. This includes all buffers
referenced by recorded kernels/copies/fills: model, state, control, contact and
solver caches. It deduplicates aliases by real base pointer and capacity,
rejects partial overlaps and escaped graph-scoped scratch, and registers the
entire numeric union as named inputs to **every** graph. The native adapter then
copies this union from the last-active graph before each different operation.
No device pointer scanning or bit-width-based type guessing is used.

Only typed float32/float64/int32/int64/bool numeric elements (including typed
vectors/matrices/transforms over those scalars) enter this union. Persistent raw
uint8 buffers are not approved merely because they have one-byte elements:
packed structs may carry pointers. Unknown uint64/handle/struct/Fabric memory is
rejected. A known immutable exception is Newton `Model.shape_source_ptr`, whose
nonzero uint64 values must match actual `wp.Mesh.id` values in that model's
`_mesh_keep_alive`/`heightfield_meshes` registries. Each graph retains its own
official APIC mesh serialization and explicit `(offset=0,stride=8)` handle
relocations. Those per-graph handles are **never** copied as numeric state.
Unknown Bvh/Volume/HashGrid/geometry handles remain unsupported.

The producer writes `manifest.json` only after all captures, region audits,
official `capture_save` calls and output hashes succeed. Failed captures can
leave an incomplete output directory, but no complete manifest is asserted.
The manifest's capture contract describes this fixed source recipe and static
checks; it is not a claim of executed export/replay equivalence.

## Bounded N4/N8 authoring and independent oracle

[`g1-apic-export-4env.json`](../../../examples/learning/g1-apic-export-4env.json)
and [`g1-apic-export-8env.json`](../../../examples/learning/g1-apic-export-8env.json)
change only `num_envs` and the fresh output directory from the existing N2
configuration. The same actuator settings, `Physics=mujoco` variant and disabled
self-collision isolate the batch-size change. These are not newly strict-paper
artifacts. Configuration without `capacity_profile` retains the 128-world cap.

The producer records actual file counts, total serialized payload bytes,
largest file and persistent numeric union bytes in `authoring_resources`.
Payload hashes are streamed in 64 KiB chunks. Export refuses more than 4,096
files, a file above 256 MiB, total payload above 1 GiB or a numeric union above
512 MiB. These are artifact bounds checked after capture, not CUDA-allocation
or complete-process peak measurements; the external memory/deadline guard is
still necessary during authoring.

`"capacity_profile":"paper-4096"` is an explicit opt-in for a separately
bounded 4096-world authoring attempt. It raises only the fixed APIC artifact
caps to 2 GiB numeric union, 4 GiB total payload and 1 GiB per payload file;
the 4096-file count and each Warp region's signed-32-bit byte bound remain.
For this profile the 1 GiB member cap also applies to each persistent shared
region, matching the native bundle reader; `initial` keeps its original
union-only producer rule.
The manifest itself is bounded to 4 MiB for `initial` and 64 MiB for
`paper-4096`, checked before publication. The exact selected profile and its
limits appear in the new manifest; missing
profile means `initial` and preserves the 128/512 MiB/1 GiB/256 MiB limits.
Unknown names fail before SDK launch. A 4096-world graph has **not** been
exported or replayed; these post-capture bounds do not predict SDK/CUDA peak
memory. A fresh external cgroup, GPU free-memory admission and telemetry are
required before an actual large authoring attempt. New manifests still set
`runtime_validated=false`.

`trace-sdk` retains the original N2/v1 tape SHA and its readback schedule.
Tape v2 supports N=4..the selected profile maximum with required
`selected_worlds=[0,N/2,N-1]`, integer
division, and the existing operation payload fields. Its fixed generator emits
27 operations/eight steps, including an initial all-world reset, empty reset,
isolated reset/context for each selected world and repeated refresh. The oracle
validates 8..64 operations, at most 16 steps, unique/in-range IDs, exact payload
shapes, finite inputs and unit reset quaternions before opening the SDK.
The original oracle input limit remains 4 MiB; only the explicit `paper-4096`
profile admits a tape up to 64 MiB. The bundle manifest must declare the same
profile, with legacy manifests interpreted as `initial`.

The v2 result is `moonrobo.apic-sdk-oracle.v2`, with `num_envs`,
`selected_worlds`, the manifest/tape hashes and the existing SDK identity. The
nine readback fields retain their meanings; per-world rows follow
`selected_worlds`, while `ground_friction` contains every static ground shape.
Real Warp `[world:world+1]` views are transferred one selected row at a time,
with at most 4,096 scalar values per row. This avoids expanding the full
N-world output on the host. Input/reset buffers still contain the complete
N-world mask and targets required by the untouched SDK API.

```sh
reference_apic_export_legacy export /absolute/export-4env.json
reference_apic_export_legacy trace-sdk /absolute/export-4env.json \
  /absolute/audit-tape-v2.json /absolute/g1-4env-apic/manifest.json \
  /absolute/fresh/sdk-oracle-v2.json
```

The oracle calls the original `InteractiveScene.write_data_to_sim` and
`SimulationContext.step`, plus the original public reset mask writers. It does
not replay exported graphs or reuse the lowered command writer as its physics
oracle. The separate output-poison writer diagnostic remains N2/v1 only.
No tolerance or prior evidence changes with this extension.

[`run_spark_apic_n4_gate.mbtx`](../../../scripts/run_spark_apic_n4_gate.mbtx)
runs one fixed N4 or explicitly selected N8 step inside an already
resource-limited container. The original three-argument CLI defaults to N4;
the only optional argument is `--num-envs 4|8`. Other batch sizes are refused.
It requires
16 GiB memory, zero swap and a finite CPU quota of at most four cores. Its only
modes are `export`, `oracle` and `replay`; deadlines are 600, 300 and 180 seconds
respectively, with a five-second TERM-to-KILL allowance. It does not create a
container, connect to another host, compile code or choose a different dataset.

Pass a bounded JSON pin file containing `executable`, `executable_sha256`,
`expected_image_id` and `adapter_sha256`. Oracle/replay additionally require the
actual new `tape_sha256` and `manifest_sha256` for the selected batch; replay
requires `oracle_sha256`.
The original authoring image/bridge and G1 asset hashes are fixed in the helper.
The rebuilt v2 native adapter/image hashes must come from the actual build;
the host must verify the selected Docker image ID before starting its container.
An image ID stated inside a container is recorded, not independently verified.

Keep the same writable `/gate` evidence mount across the separate authoring and
native containers for one batch. Use a separate fresh mount for N8 to preserve
the frozen N4 results. Stage the selected tape at `/gate/tape-v2.json` using the
native audit's `emit-tape --num-envs 4` or `8`; all result paths must be fresh.
The helper selects `g1-apic-export-{N}env.json`, `/gate/g1-{N}env-apic`, and
selected worlds `[0,2,3]` for N4 or `[0,4,7]` for N8. The operation tape remains
27 operations/eight steps. All pin, memory and deadline rules remain identical.
After compiling the helper, run each applicable command in its pinned container:

```sh
run_spark_apic_n4_gate export /gate/export-pins.json
run_spark_apic_n4_gate oracle /gate/oracle-pins.json
run_spark_apic_n4_gate replay /gate/replay-pins.json
```

For the separate N8 mount, append the explicit option to each step:

```sh
run_spark_apic_n4_gate export /gate/export-pins.json --num-envs 8
run_spark_apic_n4_gate oracle /gate/oracle-pins.json --num-envs 8
run_spark_apic_n4_gate replay /gate/replay-pins.json --num-envs 8
```

Each step saves its fixed command, verified hashes, separate stdout/stderr,
before/after cgroup counters and summary under `/gate/MODE-evidence`. A failed
comparison remains a failure with its report retained. The existing
[`watch_container_memory.mbtx`](../../../scripts/watch_container_memory.mbtx)
can independently monitor the container from its host; neither snapshot source
certifies a complete lifecycle peak or a memory figure limited to one step.

## Remaining execution boundary

The local host has no complete matching IsaacLab/Newton CUDA SDK. Public Warp
APIC APIs make this concrete producer implementable, but they do not guarantee
that every actual G1 region/kernel/library call on a later installed SDK is
supported. The producer deliberately fails on unknown persistent opaque memory,
unsafe lazy reads, non-affine direct-write views, unsupported captures or missing
module binaries. The actual SDK/GPU export, complete operation coverage review,
masked-reset isolation, context readbacks and physical replay differentials must
be repeated for each newly authored N4/N8 artifact. The retained N2 results do
not certify the larger batch. No fabricated `.wrp`, kernel module or success fixture is
checked in. Warp conditional rebuilds may still require its native NVRTC/cache
dependency even though deployed physics replay has no Python dependency.

Primary sources used for the fixed recipe:

- [Pinned IsaacLab environment](https://github.com/isaac-sim/IsaacLab/blob/46d6cc3d7b115906fad12efd372fbf69f4e3d3ed/pyproject.toml)
- [Pinned Newton manager](https://github.com/isaac-sim/IsaacLab/blob/46d6cc3d7b115906fad12efd372fbf69f4e3d3ed/source/isaaclab_newton/isaaclab_newton/physics/newton_manager.py)
- [Pinned MuJoCo-Warp manager reset](https://github.com/isaac-sim/IsaacLab/blob/46d6cc3d7b115906fad12efd372fbf69f4e3d3ed/source/isaaclab_newton/isaaclab_newton/physics/mjwarp_manager.py)
- [Pinned Newton solver](https://github.com/newton-physics/newton/blob/71eeba16a717d4dcf0b9dd7056a7b6f863054dc3/newton/_src/solvers/mujoco/solver_mujoco.py)
- [Pinned Newton model handle ownership](https://github.com/newton-physics/newton/blob/71eeba16a717d4dcf0b9dd7056a7b6f863054dc3/newton/_src/sim/model.py)
- [Warp 1.17 APIC registry](https://github.com/NVIDIA/warp/blob/v1.17.0/warp/_src/apic/capture.py)
- [Warp 1.17 capture/save implementation](https://github.com/NVIDIA/warp/blob/v1.17.0/warp/_src/context.py)
- [Warp 1.17 APIC C API](https://github.com/NVIDIA/warp/blob/v1.17.0/warp/native/apic.h)
