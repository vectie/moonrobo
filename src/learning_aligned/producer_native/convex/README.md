# Native GPU convex GJK subset

This MoonBit package emits real typed CUDA GJK computation from fixed
**MuJoCo-Warp 3.15.0**, with the existing NVRTC **C ABI** compiler and actual
Warp **1.17.0** array/launch ABI. It implements full signed-volume simplex
distance reduction (line, triangle, tetrahedron), support iteration, Frank–Wolfe
stopping, original cutoff lower bounds, approximate witness recovery, and
`gjk_phase` sphere/capsule shrinking and shallow-penetration inflation.
It is not only a support map or a CPU collision substitution.

The supported geometry types are actual MuJoCo IDs: sphere 2, capsule 3,
ellipsoid 4, cylinder 5, box 6, mesh 7. Mesh support uses the genuine exhaustive
`graphadr == -1` branch, including cached-point tie selection and global/local
vertex-index conventions. This computes convex-hull support of supplied vertices;
it does not triangulate or solve nonconvex triangle collision. Plane, hfield
prisms, SDF, flex, triangle pseudo-geoms and unknown IDs fail closed. Newton's
GeoType enum has different numbers and must not be passed unchanged.

**EPA and manifolds remain unsupported.** A candidate requiring EPA gets status
10 and increments its rejection counter. Iteration exhaustion gets status 11;
invalid or nonfinite intermediate results get 13. The source's low-dimensional,
nonseparated boundary case is conservatively rejected (13) rather than publishing
a witness with no stable normal. There is no fallback contact, fabricated depth,
CPU execution, or claim of complete narrowphase/solver/timestep closure.

`Request` (FromJson/ToJson) has exactly these fields:

| Field | Meaning |
| --- | --- |
| `nworld`, `ngeom` | Positive actual model dimensions |
| `candidate_capacity` | Positive capacity of candidate-indexed arrays |
| `vertex_capacity` | Nonnegative capacity of actual owned local vertex stream |
| `gjk_iterations` | Explicit iteration limit, 1–4096 |
| `tolerance` | Finite scalar, 1e-15 through 1e15, converted to float32 |
| `cutoff` | Finite nonnegative inflated-geometry cutoff, through 1e32; >=1e30 disables cutoff pruning |

`lower(Request)` performs source generation and hashing without NVRTC, model or
GPU initialization. `Lowered.entry` supplies `forward`, one-dimensional
`launch_shape`, and ordered typed parameters. `compile_specialization` accepts
`CompileConfig {request,mujoco_warp_root,warp_native,nvrtc_library,options,kind,output}`.
`kind` is `ptx` or `cubin`, with exactly one explicit matching architecture.
Compilation writes actual source `gjk.cu`, image, log, pinned upstream snapshots,
all supplied native headers, and `manifest.json` last into a fresh directory.
Its format is `moonrobo-native-convex-gjk-module-v1`; this is an actual compiled
module format, not a fabricated Warp `.meta` file.

The launch ABI is genuine `wp::launch_bounds_t<1>` by value, with
`coord_mult=1`, followed by these **19** genuine `wp::array_t<T>` views:

| Order | Name | Element / rank | Required shape |
| --- | --- | --- | --- |
| 0 | `geom_type` | int32 / 1 | >=ngeom |
| 1 | `geom_size` | vec3f / 2 | positive batch count, width >=ngeom |
| 2 | `geom_xpos_in` | vec3f / 2 | >=nworld, >=ngeom |
| 3 | `geom_xmat_in` | mat33f / 2 | >=nworld, >=ngeom |
| 4–5 | `geom_vertexadr`, `geom_vertexnum` | int32 / 1 | >=ngeom |
| 6 | `mesh_vertex` | vec3f / 1 | >=vertex_capacity |
| 7 | `ncollision_in` | int32 / 1 | >=1 |
| 8 | `collision_pair_in` | vec2i / 1 | >=candidate_capacity |
| 9 | `collision_worldid_in` | int32 / 1 | >=candidate_capacity |
| 10 | `collision_margin_in` | float32 / 1 | >=candidate_capacity |
| 11 | `distance_out` | float32 / 1 | >=candidate_capacity |
| 12–13 | `witness1_out`, `witness2_out` | vec3f / 1 | >=candidate_capacity |
| 14–17 | `simplex_dim_out`, `separated_out`, `iterations_out`, `status_out` | int32 / 1 | >=candidate_capacity |
| 18 | `rejected_out` | int32 / 1, inout | exactly five contiguous values |

Other arrays are inputs or outputs as their names indicate. Property batches
use `world % geom_size.shape[0]` as upstream. Per-candidate margin is the actual
**resolved pair margin assigned to both geoms**, matching `ccd_kernel_builder`;
it is not half the pair margin or an uncombined geom material margin. It must be
finite/nonnegative for this supported subset. Candidate preparation, filtering,
material mixing and per-world tolerance/cutoff batching are caller duties.
This specialization uses the one explicitly requested tolerance and cutoff for
all candidates; separate modules can express distinct values.

Mesh vertices must already be in each actual geom-local coordinate system.
Instance scale, asset centering/rotation and authored geometry resolution are not
performed here. Actual vertices may be uploaded from a prepared mesh's points
bytes only when those semantics match. A CPU Warp Mesh.id is never a GPU vertex
pointer or an array owner. Each mesh's nonnegative `vertadr` and positive
`vertnum` must fit both specialized capacity and the actual vertex view. Primitive
geom vertex metadata is unused. Exhaustive support uses finite vertices, with no
pretend hull/graph cooking. A zero-capacity vertex view is allowed for a primitive
query if the launcher can represent it using a genuine live backing Buffer.

Poses must contain finite right-handed orthonormal rotations; scaled/sheared
matrices reject. Dimensions must meet the actual primitive support requirements.
Origin is shifted to geom1 before GJK, preserving upstream translation-precision
behavior, then restored for published witness points. Arbitrary raw USD meshes
and Newton fields are not implicitly interpreted as final MuJoCo Geom layouts.

The outputs retain **GJK-phase semantics**:

- `distance_out` is distance between **margin-inflated** geometries. The final
  upstream contact wrapper additionally adds the candidate margin; this stage
  does not generate that final material contact writer.
- Witnesses are world coordinates on those inflated/shrunk-then-inflated shapes.
  Status 2 has no witness: its zero output slots must not be used as points.
- `separated_out` is the last core-GJK separation flag, possibly for the shrunken
  sphere/capsule query, so negative shallow physical distance can coexist with
  that flag. It is not a final contact-existence flag.
- `simplex_dim_out` and `iterations_out` describe the last actual GJK invocation;
  a deep sphere/capsule path can invoke it twice.

| Status | Meaning |
| --- | --- |
| 0 | Inactive slot, at or beyond actual candidate count |
| 1 | Original approximate distance/witness return |
| 2 | Certified cutoff lower bound, distance sentinel 1e30 and no witness |
| 3 | Shallow sphere/capsule inflated witness/distance |
| 10 | EPA required but unsupported |
| 11 | Iteration budget exhausted |
| 12 | Invalid index, candidate count, view descriptor or mesh extent |
| 13 | Invalid geometry, numerical result or unresolved degeneracy |
| 14 | Unsupported geometry type |

Initialize all five rejection counters to zero before a launch. Their slots map
to statuses 10–14. Each candidate contributes at most one rejection, so there is
no unbounded append/contact counter. Native descriptor gates run before indexed
access; malformed rejection storage itself returns without writes and is
prevented by the mandatory host validator. Every inactive output slot is reset,
so old status cannot silently pass after candidate-count changes.

Before launch, `validate_bindings(request, bindings)` must receive metadata from
actual owned live buffers. It checks exact names/types/ranks, shape capacity,
nonnegative aligned byte strides, complete Int64 footprint, overflow, writable
internal aliasing and any writable overlap with another view. Read-only
broadcast inputs are supported. Fake pointer extents are outside this contract.
After completed synchronized GPU readback, callers must invoke
`validate_results(request, actual_count, actual_status, actual_rejected)`:
all active statuses must be 1–3, inactive statuses zero, and every rejection
counter zero. Record-only capture cannot claim this gate passed. A later contact
consumer still needs to interpret cutoff status and phase-distance semantics;
passing this gate does not manufacture final contacts or an EPA manifold.

The module records an explicit 256-thread, zero dynamic shared-memory,
grid-stride launch policy. It hashes four complete pinned sources plus relevant
helper definitions, generated source, specialization request, genuine header
bytes, actual compiler bytes/options/version, actual image and log. Only
`builtin.h`/`array.h` are release-attested; other header bytes are observed and
snapshotted, with external include/native transitive dependencies unattested.
Source definition receipts are evidence of upstream identity, not a claim that
unsupported hfield/EPA parts of those functions have all been migrated.

Validation so far is **static only**: MoonBit check/info/fmt, and host C++ helper
expression `-fsyntax-only` against actual Warp 1.17 headers. The optional
`tools/extract_host_helper_syntax.mbtx` performs only filesystem/text extraction,
removing `__device__` annotations for that limited host check. It does not call
`lower` or any numerical function. This does not verify CUDA launch compilation
or NVRTC. No algorithm, tests, example, model/SDK initialization, GPU launch or
NVRTC compilation has run. Original Python and existing CPU/primitive routes
remain unchanged.

Deferred checks cover signed-volume/minor tie and degeneracy cases, transformed
box/cylinder/ellipsoid and convex mesh witness comparisons, cached support ties,
origin translation, cutoff and margin boundaries, shallow/deep sphere/capsule,
EPA/iteration rejection, invalid geometry/views, runtime launch/capture and
completed-readback gates. Three contract tests have only been typechecked.
Numerical equivalence requires later execution on the pinned stack.

Upstream: MuJoCo-Warp 3.15.0 `collision_gjk.py`, `collision_convex.py`,
`collision_core.py`, `types.py`; Copyright 2025 The Newton Developers,
Apache-2.0. Fixed hashes and source definitions are recorded in the compiler
receipt and `sources.json`.
