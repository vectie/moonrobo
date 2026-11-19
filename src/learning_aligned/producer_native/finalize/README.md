# Native rigid-tree model/state/control buffers

This package implements a concrete subset of Newton-style rigid-tree host
finalization and device storage. It packs real typed model, two state copies
and control buffers from the MoonBit builder's prepared numerical arrays.
It does not construct a Newton `Model` object or claim a complete solver model.

The JSON input is `CommandRequest`:

```json
{
  "builder_request": {
    "usd_receipt": {},
    "num_envs": 1,
    "self_collisions": true,
    "placements": [{"position": [0,0,0], "quaternion_wxyz": [1,0,0,0]}]
  },
  "scalar_type": "f64",
  "target_layout": "coord"
}
```

`usd_receipt` must contain the real native OpenUSD receipt, including its actual
articulation IR; the empty object above only marks where to insert it. The
builder validates the supported G1 tree and computes real initial kinematics.
`scalar_type` is explicitly `f32` or `f64`; `target_layout` is explicitly `coord`
or `dof`. No hidden global Python target-layout toggle is read.

`prepare(request)` and `prepare_arrays(prepared, scalar_type, target_layout)`
create a `HostLayout`. `HostLayout.array(name)` returns copied typed bytes and
shape metadata. The actual arrays include:

- Body and joint/world maps, ancestor and articulation membership, DOF dimensions,
  coordinate/DOF prefix arrays, and real `world_count + 2` world-start arrays
  with global-tail and total sentinels.
- `model.body_q`, `body_qd`, joint anchor transforms, axes, coordinates, velocity,
  armature, motor gains/limits and default gain-derived target modes.
- Two independently packed `state0`/`state1` copies with body/joint poses and
  velocities, and actual zero-initialized body-force buffers.
- Independently packed control targets, target velocities, force and feedforward
  inputs. Free-coordinate targets have a valid identity quaternion; they are
  distinct from the moving root's state pose. Legacy DOF targets omit the free
  quaternion's padding slot and contain zero free-axis targets.
- Complete authored mass/COM/inertia and inverse buffers when every body provides
  them. If any body requires inference, those physical arrays are absent and the
  layout reports `mass_properties_complete:false`.

Names match corresponding Newton fields where implemented. Static integer
property aliases such as `joint_target_q_start` are separately stored equal
arrays in this package, rather than shared Python property objects. `state0`
and `state1` are independent buffers; this corresponds to `Model.state()`
cloning, not the manager's optional single-state aliasing policy.

Arrays use contiguous little-endian storage. `shape` describes Warp array axes;
`components` describes one element. For example a transform array has shape
`[body_count]`, seven float components and a 28-byte stride under `f32`, not a
rank-two scalar descriptor. Integer arrays use i32, enabled flags use one-byte
bool, and physical values use the requested float width. f32 conversion rejects
nonfinite data, overflow and underflow to zero. The f64 mode supports CPU/Double
reference preparation; it is not the pinned Newton float32 ABI. Unlimited joint
limits use the pinned Newton `MAXVAL=1e10` conversion.

`finalize_artifact(request, output)` is an explicit host-only command. It writes
a fresh directory containing each actual `.bin` array, `request.json` and
`layout.json`. Every array has dtype, rank, component count, stride, length and
SHA256 metadata; the normalized request also has a recorded SHA256. There is no
Python, NumPy, device initialization, CUDA library load, SDK import, JIT or
automatic upload in this command. Filenames are fixed generated array names.

`upload(layout, context)` is a separate explicit execution API. It calls the
existing `dispatch.Context.allocate` and `Buffer.write`, which use real Warp
native C functions. Upload snapshots metadata/host bytes, synchronizes each
borrowed upload and returns a `DeviceLayout` retaining the actual Context and
all Buffer owners. Partial failure closes created child handles. No context is
created by this package and the supplied Context remains caller-owned.

`DeviceLayout.argument(name)` returns a real typed dispatch argument, preserving
element widths and byte strides. `pointer(name)` returns UInt64 directly without
a floating-point JSON round trip. `download(name)` explicitly performs a
synchronized readback for future checks. `close()` waits for submitted work,
closes child handles and is idempotent; the underlying dispatch arena can retain
allocations until its last Context/Buffer/Kernel owner is released. It never
closes the caller's Context. Keep the DeviceLayout and the actual external CUDA
context owner alive for every graph using those addresses. Closing it while a
recorded graph can still be launched violates that ownership contract.

The source audit is pinned to Newton
`71eeba16a717d4dcf0b9dd7056a7b6f863054dc3`. [sources.json](sources.json) records the
SHA256 of each inspected primary source:

- [`ModelBuilder._finalize_impl`](https://github.com/newton-physics/newton/blob/71eeba16a717d4dcf0b9dd7056a7b6f863054dc3/newton/_src/sim/builder.py)
  establishes body/joint typed arrays, start sentinels, ancestor/membership maps
  and world-start conventions. Only the identified rigid-tree subset is ported.
- [`Model.state/control`](https://github.com/newton-physics/newton/blob/71eeba16a717d4dcf0b9dd7056a7b6f863054dc3/newton/_src/sim/model.py)
  clone model state/control arrays and zero body forces. Custom namespace and
  optional extended-state allocation remain outside this subset.
- [`Control`](https://github.com/newton-physics/newton/blob/71eeba16a717d4dcf0b9dd7056a7b6f863054dc3/newton/_src/sim/control.py)
  and [`enums`](https://github.com/newton-physics/newton/blob/71eeba16a717d4dcf0b9dd7056a7b6f863054dc3/newton/_src/sim/enums.py)
  define target layout and default gain-based modes; explicit authored modes
  and forced position/velocity overrides are not inferred here.

Full shape/contact/constraint/particle/muscle storage, mesh cooking, automatic
inertia correction, schema-resolver overrides, solver namespaces, graph/state
alias contracts, optional extended state and exact float32 parity remain
unimplemented. The artifact therefore always reports `full_finalize_complete`,
`newton_model_constructed` and `numerical_equivalence_verified` as false. A
successful upload proves storage creation only, not solver compatibility.

Only MoonBit check/info/fmt were run during this change. Pending test sources
cover exact scalar/vector byte layouts, world-start ownership, valid free target
quaternions, legacy target projection and malformed/unrepresentable inputs.
No test, layout preparation, artifact writing, allocation, upload, download,
context creation, SDK, GPU, model/USD conversion or JIT was executed.

## Resolved primitive shapes and real Contacts storage

`prepare_collision(CollisionRequest)` extends the actual rigid-tree layout;
`collision_artifact(request, output)` writes the same physical-owner binary
format and explicit alias metadata. Its JSON request contains `base` (the
`CommandRequest` above), `shapes`, `filters:[{a,b}]`, `candidate_limit` and
`contacts`. Shape/filter indices refer to the global prepared arrays, and are
never inferred from shape names. This API does not resolve a USD schema.

Each shape supplies `kind`, `body`, `world`, `transform` (MoonNum's rigid
`Transform3` JSON), `scale` (`{x,y,z}`), `material`, `flags`, `collision_group`,
`margin`, `gap`, `collision_radius` and `is_solid`. Attached transforms are
body-local; static (`body:-1`) transforms are world transforms. Attached world
must equal the body's actual owner. Worlds must be contiguous with optional
global (`world:-1`) prefix/tail, preserving Newton's world-start representation.
The request must supply already resolved, nonnegative dimensions/materials;
mirroring and defaults are not inferred. Rigid rotations are validated.

Supported Newton `GeoType` codes and canonical builder scales:

| kind | code | scale |
| --- | --- | --- |
| plane | 1 | `(halfwidth, halfheight, 0)`, zero extents allowed |
| sphere | 3 | `(radius, 0, 0)` |
| capsule | 4 | `(radius, halfheight, 0)`; local Z axis |
| ellipsoid | 5 | `(rx, ry, rz)` |
| cylinder | 6 | `(radius, halfheight, 0)`; plain cylinders only |
| box | 7 | `(hx, hy, hz)` half extents |
| cone | 9 | `(radius, halfheight, 0)`; apex at positive local Z |

These codes are Newton codes, not MuJoCo codes. Mesh/hfield/SDF/cooked geometry,
barrel cylinders, site/hydroelastic/unknown flags are rejected. Visibility,
COLLIDE_SHAPES and COLLIDE_PARTICLES bits may be stored, but no particle
simulation is supplied. Materials require explicit `ke,kd,kf,ka,mu,restitution,
mu_torsional,mu_rolling,kh`. Margin/gap/radius are authored resolved inputs, not
newly inferred collision properties. Mass/inertia remain the original explicit
body properties; shape mass aggregation and inertia correction are not ported.

The layout adds real `model.shape_*` arrays, zero primitive source pointers,
primitive support-data sentinels and convex fallback buffers. It implements the
pinned builder's **generic** `_find_shape_contact_pairs` branch: stable
world/index ordering, same-body/static-static rejection, world/group rules and
sorted explicit exclusions. The replicated fast-path ordering is not claimed.
`model.shape_contact_pairs` is the actual eligible `vec2i` list, with its scalar
count in `storage_scope`; this is not dynamic AABB broadphase or generated
contacts. `prepared.shape_collision_filter_packed` stores exact sorted unique
int64 codes `(min<<32)|max`; upstream keeps this as a host NumPy-backed object,
so this is explicitly auxiliary serialization. `prepared.body_shape_*` is an
auxiliary CSR encoding of the upstream host dictionary. Candidate capacity
overflow rejects rather than truncates. Shapes are bounded at 4096 and pairs
at one million.

`contacts` fields are `rigid_max`, `soft_max`, `requires_grad`,
`per_contact_shape_properties`, `contact_matching`, `contact_report` and
`surface_velocity`. The supported stream is Newton's global rigid Contacts
stream, not per-world MJWarp contact records. `soft_max` must be zero,
`requires_grad` false, and report requires matching. Real point/offset/normal/
margin/force/tid/shape arrays are initialized exactly as `Contacts.__init__`,
including shape/tid/matching `-1` sentinels and optional material/report/surface
velocity arrays. Zero-capacity soft storage remains represented by empty
owners. No contact generation or solve occurs.

`contacts.contact_counters` owns one int32[3] allocation. Rigid count, soft
count and reduction-overflow are true views at byte offsets 0, 4 and 8;
`rigid_contact_diff_normal` aliases the normal buffer. `array_names()` returns
physical owners only, while `view_names()` includes aliases. Owner bytes are
serialized/hashed/uploaded once. Aliases have a checked direct owner, alignment,
shape and in-bounds span; `array()` returns a copied view. Device arguments,
pointers and readback preserve offsets into that same physical owner. Old
state0/state1/control buffers remain independent. Empty owners are retained in
metadata, skipped during allocation, yield pointer zero/empty readback and
explicitly reject dispatch arguments. f64 shape/contact storage is a Double
reference representation; pinned Newton uses float32 fields.

Additional sources are pinned `geometry/types.py` (`GeoType`),
`geometry/flags.py` (`ShapeFlags`) and `sim/contacts.py` (`Contacts.__init__`),
with SHA identities in `sources.json`. Pending regression sources cover group/
world/filter ordering, exact packed exclusions, canonical primitive encodings,
empty arrays, contact sentinels and actual alias bounds/ownership. They have
only been typechecked. Full finalize, custom namespaces, constraints, geometry
cooking, inferred inertia, collision execution and equivalence remain false.
