# Native primitive contact subset

This package implements real typed CUDA contact generation for seven primitive
pairs from the **MuJoCo-Warp 3.15.0** source distribution:

| Pair | Implemented geometry and original corner cases |
| --- | --- |
| `plane-sphere` | Signed surface distance, midpoint position and plane-normal frame |
| `sphere-sphere` | Surface distance and midpoint; coincident centres retain the original +X normal |
| `sphere-capsule` | Original segment closest point, including the `+1e-6` denominator, followed by sphere contact |
| `plane-capsule` | Both endpoint contacts, original capsule-aligned frame and its near-parallel fallback; contact IDs 0 and 1 |
| `sphere-box` | Outside closest point and inside nearest-face branch, preserving face tie order and normal direction |
| `plane-box` | All **eight** original corner contacts and IDs 0–7; the source wrapper emits all eight despite its core comment referring to four |
| `capsule-capsule` | Original determinant branch, clamped segment coordinates, ordered four endpoint checks for parallel axes, first two contacts passing the material margin, and original two wrapper slots |

The generator also ports `collision_core.contact_params`: explicit pair
overrides; per-world property batches; geom priority; tiny `solmix` branches;
positive-reference blending versus component minimum; five friction components
and the `mjMINMU` floor; adhesion; summed margin and gap. It ports the actual
`write_contact` behavior: strict distance comparisons, adhesive condim reduction,
sensor-only pair IDs, constraint/sensor flags, atomic contact count, include
margin, all material outputs and all EFC address slots reset to -1.

`lower(Request) -> Lowered` produces source, typed entry metadata and source /
specialization SHA without loading NVRTC. `compile_specialization(CompileConfig)`
connects that source to the existing MoonBit → NVRTC **C ABI** binding. No Python
interpreter participates in these operations. Original Python files are passive
source-identity inputs and remain unchanged.

```json
{
  "request": {
    "nworld": 2, "ngeom": 40,
    "candidate_capacity": 100, "contact_capacity": 800, "efc_slots": 10,
    "pairs": ["plane-sphere", "sphere-sphere", "sphere-capsule",
              "plane-capsule", "sphere-box", "plane-box", "capsule-capsule"]
  },
  "mujoco_warp_root": "/sdk/mujoco_warp-3.15.0",
  "warp_native": "/sdk/warp/warp/native",
  "nvrtc_library": "/sdk/cuda/lib64/libnvrtc.so",
  "options": ["--gpu-architecture=compute_90", "--fmad=false"],
  "kind": "ptx",
  "output": "/output/fresh-native-contacts"
}
```

Counts and architecture above illustrate the schema; use actual model and
allocation metadata. `efc_slots` is `nmaxpyramid`, not the contact count or condim.
The entry is `mr_mjw_native_primitive_contacts`, using genuine Warp 1.17
`launch_bounds_t<1>` by value with `coord_mult=1`, followed by the 42 ordered
metadata parameters. Arrays use genuine `wp::array_t<T>` byte-stride views;
`vec5f` is exactly `wp::vec_t<5,float>`. Mesh-only arguments from the upstream
generic kernel are deliberately absent from this finite entry ABI.

The candidate arrays **must** come from the real upstream filtering stage:
`contype`/`conaffinity`, parent/exclude/body rules and authored pair selection are
not implemented here. Geom type ordering must be the ordering produced by
`_add_geom_pair`. Reversed or unselected pairs are rejected, not silently swapped.
Box-box, cylinders, ellipsoids, GJK/EPA, convex/mesh, hfield,
flex and SDF collisions are outside this subset. Unknown requested pair keys
raise before compiler loading. Encountered unsupported candidate types increment
`rejected_out[0]` and produce no fallback contact.

Capsule-capsule resolves actual mixed material margin before geometry. It keeps
the source's `abs(det) >= 1e-15` branch and division behavior, with no added
epsilon or sphere fallback for zero-length capsules. Both wrapper slots remain
present: invalid slots have `+inf` distance and zero position/frame, so the
upstream sensor-only write semantics remain observable. This does not add a
general convex algorithm. The independent [`collision_native`](collision_native/README.md)
package binds the actual MuJoCo 3.3.7 CPU C collision implementation for mesh,
hfield and other supported rigid geometry in an existing MJB. It uses a separate
model/state ABI and does not replace the Newton/MuJoCo-Warp backend.

Before constructing launch Arguments, callers **must** call
`validate_bindings(request, actual_owned_buffer_views)`. Each FromJson `Binding`
contains `name`, backing `allocation` identity, `dtype`, `shape`,
`byte_strides`, `byte_offset` and actual `buffer_bytes`. The metadata must be
derived from live owned native Buffer/View objects. The validator checks:

- exactly 42 named typed views and their real rank/dimension requirements;
- byte-stride footprint within the backing allocation, offset/stride alignment
  and overflow;
- writable elements do not internally alias and writable views do not overlap
  any other view in the same backing allocation;
- real geom/world/candidate/contact capacities, material batch widths and EFC
  slot count, plus two contiguous int32 rejection counters.

Input broadcasts with nonnegative byte strides are supported; writable
broadcasts, negative strides and conservatively overlapping writable views are
rejected. The native entry independently checks every descriptor rank/shape,
nonempty data pointer, minimum capacity and nonnegative aligned stride before
indexing. A malformed rejection-counter descriptor returns without touching
other data; the mandatory host validator prevents that case. Shape checks
cannot prove arbitrary raw GPU pointers own the claimed memory. Launching raw,
unvalidated descriptors is outside this API's supported contract.

Initialize rejection counters to zero and contact count to a valid nonnegative
append position (normally zero). `rejected_out[1]` records malformed candidate
indices/batches, candidate-count overflow and contact-capacity overflow. The
contact atomic counter still increments on capacity overflow, preserving the
upstream count; out-of-capacity output slots are not written. Counts/capacities
are bounded to avoid signed counter wrap for valid append positions.
**Neither rejection counter may be nonzero, and contact count may not exceed
capacity, before contacts are published or used for constraints.** Partial
supported contacts are not a complete result when another candidate was rejected.

Compilation SHA checks six complete pinned source files and hashes every
ported geometry/wrapper/material/write/frame helper definition. It snapshots
the original bytes as `.source` files, genuine native headers, effective compiler
options/version, generated source, image and logs. Only `array.h` and `builtin.h`
are attested against the pinned Warp release; other supplied header bytes are
observed and snapshotted. Extra include files and native compiler dependencies
are explicitly outside that attestation. The manifest is written last in a
fresh output folder and states all remaining capability limits.

This is a primitive contact subset, not full narrowphase, collision, constraint,
solver or timestep closure. No Warp `.meta` file or APIC capture is fabricated.
Atomic contact ordering, floating-point results, margins and learning results
still require later differential execution on the pinned SDK/GPU stack.

Only source check/info/fmt and read-only upstream comparison have run. Five
pending tests cover signatures, unsupported/capacity plans and actual view
footprint/alias rules. No tests, examples, source/artifact generation, NVRTC
compilation, GPU kernels, model/SDK initialization or numerical work ran.

Sources: MuJoCo-Warp 3.15.0 `collision_primitive.py`,
`collision_primitive_core.py`, `collision_core.py`, `math.py`, `types.py` and
`collision_driver.py`; **Copyright 2025–2026 The Newton Developers,
Apache-2.0**. Original copyright/license notices remain in the source snapshots.
