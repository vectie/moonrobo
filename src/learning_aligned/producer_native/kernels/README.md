# Concrete G1 typed kernels

MoonBit now lowers a fixed set of real IsaacLab kernels to CUDA C++ and connects
that source to the native NVRTC compiler. This is a finite typed lowerer, not a
Python parser or a compatible implementation of general Warp AST specialization.
The source revision is `46d6cc3d7b115906fad12efd372fbf69f4e3d3ed`.

| Key | Original kernel | Preserved operation |
| --- | --- | --- |
| `root-pose-mask` | `set_root_link_pose_to_sim_mask` | Copy selected root-link transforms |
| `root-velocity-mask` | `set_root_com_velocity_to_sim_mask` | Copy selected root COM spatial velocities and zero their body accelerations |
| `joint-position-mask` | `_write_2d_user_to_backend_with_mask`, float32 | Write selected public values; scatter through public-to-backend map only when ordered |
| `joint-velocity-mask` | `write_joint_vel_user_to_backend_with_mask` | Write selected velocity and previous velocity, zero acceleration, conditionally scatter backend velocity |
| `joint-target-mask` | `write_2d_float_with_mask` | Write selected position/velocity/effort command cells in public order |
| `implicit-actuator-batch` | `compute_implicit_actuator_batch` | Compute PD plus feedforward, clamp total effort, publish command/effort/velocity-limit outputs through the batch joint-index map |
| `joint-target-reorder` | `reorder_joint_targets_user_to_backend` | Gather effort, position and velocity targets into backend order with four independent write flags |
| `torque-telemetry` | `sync_torque_telemetry` | Preserve implicit shadow PD, its clamp and feedforward addition; preserve explicit computed/applied effort branches |
| `publish-joint-state` | `reorder_joint_state_backend_to_user` | Fused position and velocity publication through the public-to-backend map |
| `publish-body-state` | `reorder_body_state_backend_to_user` | Fused body-link transform and COM velocity publication |
| `publish-joints`, `publish-body-pose`, `publish-body-velocity` | `gather_2d` | Three concrete element-type specializations for property/state views |

The first two kernels originate in
`source/isaaclab_newton/isaaclab_newton/assets/kernels.py`; the ordering kernels
originate in
`source/isaaclab/isaaclab/assets/articulation/ordering_kernels.py`; torque telemetry
originates in `source/isaaclab/isaaclab/actuators/newton/kernels.py`.
The target-mask writer and implicit batch originate in
`source/isaaclab/isaaclab/actuators/actuator_kernels.py`.
`ArticulationData._refresh_user_order_state` actually uses the fused joint/body
publication kernels. Generic `gather_2d` alone would miss that effective path.
The PD formula here is **telemetry**, not a replacement Newton actuator or
MuJoCo-Warp's physical actuator force integration.
The separate `implicit-actuator-batch` preserves the actual Lab implicit batch
executor used when all G1 groups are `ImplicitActuatorCfg` and the native actuator
path is inactive; its batch joint map must contain the effective 29 joints.

`lower(SpecializationRequest)` returns CUDA source, source SHA, specialization
SHA and exact ordered entry parameters without loading a compiler. Requests fix
the number of environments, 29 G1 joints, the actual body count and a nonempty
list of supported keys. Generated symbols/types/body templates are fixed;
user strings cannot introduce CUDA statements or arbitrary entry names.

`compile_specialization(CompileConfig)` takes JSON such as:

```json
{
  "specialization": {
    "num_envs": 8,
    "num_joints": 29,
    "num_bodies": 30,
    "kernels": ["root-pose-mask", "joint-position-mask", "publish-joint-state"]
  },
  "isaaclab_root": "/sdk/IsaacLab",
  "warp_native": "/sdk/warp/warp/native",
  "nvrtc_library": "/sdk/cuda/lib64/libnvrtc.so",
  "options": ["--gpu-architecture=compute_90", "--fmad=false"],
  "kind": "ptx",
  "output": "/output/fresh-g1-kernels"
}
```

The body count and architecture above are examples; callers must use their
actual model metadata and target. One explicit architecture is required. C++17
and NVRTC's device default execution space are added when absent; all effective
options are recorded. No optimization or arithmetic equivalence is assumed.

Compilation checks complete pinned upstream source-file SHA values and records
each selected decorated Python definition's SHA by passive text inspection.
It snapshots the exact upstream files under `.source` suffixes. It verifies
Warp 1.17's genuine `builtin.h` and `array.h` identities, snapshots all supplied
Warp native headers and hashes them, and passes them to NVRTC as in-memory
headers. Other headers are recorded as observed bytes, without claiming every
header was checked against an upstream release. Compiler dependencies and extra
include paths are explicitly outside that attestation.

The entry ABI uses the actual Warp header declarations:

1. `wp::launch_bounds_t<N>` by value, with `N=launch_shape.length` and
   `coord_mult=1`;
2. each metadata parameter in order, arrays as `wp::array_t<T>` by value,
   scalars as their declared C++ type;
3. each array descriptor's device data/gradient pointers relocated by the native
   dispatcher. C++ scalar `bool` occupies one byte; MoonBit FFI's int32 Boolean
   representation must not be used for this CUDA parameter.

Strides are byte strides and are consumed through genuine `wp::index`; these
kernels do not assume contiguous arrays. Array shapes, selection masks,
permutation maps, disjoint publication destinations and conditional aliasing
must satisfy the original kernel contracts. In particular, a nonidentity gather
cannot safely alias its input and output. `num_bodies` in the root-velocity
kernel must match the actual acceleration view. Launch dimensions are bounded
so the total coordinate count fits a signed 32-bit index.

The result manifest records the compiler file/version/options, actual generated
source/image/log SHAs, specialization identity, upstream source/definition SHAs
and forward entry metadata. It records no adjoints and generates no Warp `.meta`
file. It does not claim a complete APIC capture, Newton model construction,
MuJoCo-Warp forward/collision/constraint/solver kernel closure, coordinate gather
for ball joints, mask invalidation/solver-reset bookkeeping, or user freshness
state. Those stages remain separate work.

Only source type checking, interface generation and formatting have been used.
The regression test sources are pending; no CUDA source compilation, module
loading, GPU launch, artifact export or numerical comparison was executed.

References: [pinned ordering kernels](https://github.com/isaac-sim/IsaacLab/blob/46d6cc3d7b115906fad12efd372fbf69f4e3d3ed/source/isaaclab/isaaclab/assets/articulation/ordering_kernels.py),
[pinned shared kernels](https://github.com/isaac-sim/IsaacLab/blob/46d6cc3d7b115906fad12efd372fbf69f4e3d3ed/source/isaaclab_newton/isaaclab_newton/assets/kernels.py),
[pinned telemetry kernel](https://github.com/isaac-sim/IsaacLab/blob/46d6cc3d7b115906fad12efd372fbf69f4e3d3ed/source/isaaclab/isaaclab/actuators/newton/kernels.py),
[Warp array ABI](https://github.com/NVIDIA/warp/blob/v1.17.0/warp/native/array.h),
[Warp launch bounds](https://github.com/NVIDIA/warp/blob/v1.17.0/warp/native/builtin.h).
