# Native convex contacts

This parallel module generates actual MoonBit-authored CUDA implementing pinned
MuJoCo-Warp 3.15 GJK, EPA, box/cylinder/mesh manifold clipping, heightfield prism
traversal, all plane primitives and plane-convex selection, followed by real
material mixing and contact-writing formulas. The original
Python and distance-only `convex` package remain unchanged. Source translation,
supported callable paths, real GPU execution and numerical parity are separate
claims: no tests, algorithms, SDK, NVRTC or GPU execution has been performed.

`lower(Request)` returns typed source plus an exact source/specialization SHA.
`compile_specialization(CompileConfig)` is a separate explicit deferred NVRTC
operation, with actual pinned upstream/reference/header snapshots and actual
PTX/CUBIN/log bytes. It does not invoke Python or synthesize a successful image.
The format is `moonrobo-native-convex-contact-module-v1`, the forward entry is
`mr_mjw_native_convex_contacts`, and pipeline entry key is `convex-contacts`.

## Actual algorithm and layout

The 69 by-value Warp array descriptors are the primitive contact module's 42
material/candidate/contact arrays, fourteen mesh views, seven heightfield views,
and six EPA scratch
views. Mesh views are `geom_vertexadr/geom_vertexnum/geom_polyadr/geom_polynum`,
`geom_graphadr`, `mesh_vertex/mesh_graph/mesh_polynormal/mesh_polyvertadr`,
`mesh_polyvertnum/mesh_polyvert/mesh_polymapadr/mesh_polymapnum/mesh_polymap`.
Vertex and polygon IDs retain actual upstream local/global index conventions.
Mesh support implements both the exhaustive cached branch and real hillclimb
with its distinct local graph-node cache. Graph and polygon contents are checked
on the device before support/manifold access, in addition to host byte proofs.
Missing polygon data (`polyadr<0`) uses the original single-witness fallback.

Heightfield views are `geom_hfieldid` (int32 rank2), `geom_rbound` (float32
rank2), `hfield_size` (vec4f), `hfield_nrow/ncol/adr` (int32) and `hfield_data`
(float32), the last five rank1. `hfield_capacity/hfield_data_capacity` are
explicit Request fields. Actual data dimensions, grid indices and normalized
samples are validated before prism traversal. Heightfield processing retains
world poses until its own local transform and uses the original geom margin
sum/rbound filter, not explicit-pair material margin. Its contact distance is
already final and bypasses the rigid CCD `+margin` correction. Plane processing
also preserves its primitive distances; plane-box emits the actual eight
corners. Plane-convex retains exhaustive/graph support ties and reverse unique
selection; sensors preserve the original four-slot `mjMAXVAL` placeholders.

The scratch views have exact shape:

| Parameter | Dtype | Shape |
| --- | --- | --- |
| `epa_vert_in` | vec3f | `[candidate_capacity, 2*epa_vertices]` |
| `epa_vert_index_in` | int32 | same |
| `epa_face_in` | int32 | `[candidate_capacity, epa_faces]` |
| `epa_pr_in` | vec3f | same |
| `epa_norm2_in` | float32 | same |
| `epa_horizon_in` | int32 | `[candidate_capacity, epa_horizon]` |

Each actual candidate owns a disjoint scratch row; there is no pointer-shaped
placeholder or a shared mutable scratch row. Face vertices retain genuine
10-bit packing; vertex capacity is at most 1024. Manifold local polygon buffers
use explicit `max_polygon_vertices` (16..1024, including the actual cylinder
16-gon), with clipping capacity checks. Scratch failure is never a success.

Actual host material semantics include explicit pair overrides, priority,
solmix, solref standard/direct mixing, friction floor, adhesion, margin/gap,
constraint/sensor flags, local manifold slot IDs and complete EFC `-1` slots.
The CCD driver shifts the origin, compares inflated distance with gap, then
adds the resolved margin back to the single-contact surface distance. Frame
direction switches according to the original overlap/gap-band rule. The
manifold's per-slot distances remain unchanged, as in the pinned driver.

`validate_bindings` is mandatory and accepts only metadata derived from the
actual live owned native Buffer/View. It proves dtype, rank, shape, alignment,
full reachable byte extent, internally disjoint writable elements and no
scratch/output overlap with other views. Native shape and actual index/content
guards complement this; a raw pointer plus an alleged count is not supported.
Initial `nacon_out[0]` must be nonnegative and within contact capacity. Pipeline
must protect its complete owner and `rejected_out` from any other writer.
`contact_capacity + 8*candidate_capacity <= INT_MAX` prevents append wrap.

`validate_results(request, actual_ncollision, actual_nacon, rejected)` must use
completed synchronized GPU readback. `rejected_out` is eight contiguous int32s:
unsupported geometry, invalid descriptor/index/contact overflow, GJK failure,
EPA vertex/face capacity, EPA horizon capacity, EPA algorithm failure,
manifold topology/capacity, and nonfinite export. Every counter must be zero;
the true contact count must fit capacity. Record-only capture cannot publish
successful contacts. All owned buffers/module/scratch must remain alive through
the final writer save, and initial memory snapshots precede capture.

## Remaining whole-program boundaries

`plan_host_schedule(HostScheduleRequest)` translates the actual upstream
`convex_narrowphase` host allocation/launch ordering and `_ccd_grid_size` math:
box-only 16 EPA iterations, global cylinder/mesh polygon sizing, typed scratch
byte footprints, hfield-first ordering and actual two-wave occupancy cap.
`warn_overflow` is the resolved original nonnegative integer mask. Actual
per-specialized-kernel occupancy is an input, never a fabricated query result;
this pure plan neither queries hardware nor allocates or launches. Its upstream
per-type builder layout is distinct from the generic 69-view terminal entry.

The new helper chain covers plane and rigid-convex geometry, heightfield
filter/prism CCD with its special support/inflate/EPA witness, and manifold
recovery. FLEX=105/TRIANGLE=999 support helpers are translated but rejected at
this rigid entry; their actual deformable candidate providers/contact writer,
upstream dynamic work queues, actual occupancy queries and full collision driver filtering are
separate callables. This module does not claim those dispatch paths or a complete
timestep/solver. Explicit failure treatment for
algorithm exhaustion/nonfinite inputs is stricter than upstream approximate
fallbacks; numerical and behavioral parity await differential checks. Source
constant expressions for face/edge angle tolerances and cylinder circle points
remain actual CUDA expressions, not an already verified bit-identical table.

Seven upstream files are strictly SHA-pinned and snapshotted, including lexical
definition SHA evidence: `collision_gjk.py`, `collision_convex.py`,
`collision_core.py`, `collision_primitive.py`, `collision_primitive_core.py`,
`math.py`, `types.py`; genuine Warp
1.17 `array.h`/`builtin.h` ABI is separately checked. See `sources.json` and the
generated public interface for complete Request and CompileConfig fields.
The chosen `mjMAXCONPAIR=50` heightfield temporary capacity and `mjMAXVAL=1e10`
placeholder are source constants independently evidenced by the fixed MuJoCo
3.3.7 `mjmodel.h`; no MuJoCo runtime was queried, and that header is not a claim
of MuJoCo-Warp 3.15 runtime/version equivalence. Hitting the 50-contact temporary
capacity refuses publication rather than silently presenting a truncated set.
Only static MoonBit checks/format/interface and genuine-header syntax review
are verification performed here. The pending metadata regression sources,
GPU GJK/EPA/manifold/contact comparisons, allocation/lifetime checks and APIC
replay have not run.

The pure-text `tools/extract_entry_host_syntax.mbtx` also extracts the complete
69-view entry signature and actual material/write/driver bodies alongside all
helpers for a genuine-Warp-header C++ host syntax check. Its declared host-only
qualifier/thread-index substitutions and representative shape-gate constants
make this a syntax review, not CUDA/NVRTC compilation or a proof that arbitrary
raw descriptors are safe. The real `validate_bindings` and generated native
guards remain mandatory.
