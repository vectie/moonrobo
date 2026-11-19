# Newton geometry cooking in MoonBit and native C/C++

This package provides actual callable geometry preparation, mass properties,
convex hulls, topology/support data, collision-edge filtering, sparse SDFs,
native Mesh/Texture/NanoVDB resources and caches. Original Python remains in
parallel. No Newton C ABI is invented and no prepared manifest is called a
Newton Model.

Sources are Newton `71eeba16a717d4dcf0b9dd7056a7b6f863054dc3`, Warp `v1.17.0`
and reentrant Qhull `2020.2`. [sources.json](sources.json) records paths, SHA256
and anchors. Native code includes genuine headers and resolves real C entry
points. The versioned local adapter ABI is separate from those native APIs.

**Only source review, check/info/fmt and genuine-header syntax-only checks
were performed. No tests, numerical/preparation algorithm, cooking, library
load, model/SDK, GPU, NVRTC, JIT or export was run.** The executed `.mbtx`
helper only verifies SHA and translates literal MC table text, without Python
evaluation or marching-cubes execution. Numerical/learning/physics parity is
pending; `full_newton_cooking_complete` remains false.

## Callable coverage

| Pinned source operation | Actual callable replacement | Boundaries |
| --- | --- | --- |
| Mesh validation/finalize arrays | `prepare_mesh`, `PreparedMesh.vertices/triangles`, `mesh_artifact` | Real contiguous little-endian f32/i32 buffers; strict explicit-triangle domain |
| Host Mesh/BVH create/refit/destroy | `open_host_mesh`, `HostMesh.id/refit_points/share/close` | Genuine Warp C API, copied owned arrays, no `wp_init` |
| Device Mesh/BVH create/refit/destroy | `open_device_mesh`, `DeviceMesh.id/refit_points/share/close` | Genuine device allocations/C API, explicit retained Context; execution deferred |
| Point/velocity gradient storage | `HostMesh/DeviceMesh.enable_gradients/zero_gradients/gradient_snapshot` | Real zeroed adjoint arrays attached to genuine `array_t.grad`; no Tape/backward claim |
| Mutable surface velocity | `HostMesh/DeviceMesh.refit_velocities` | Same copied allocation; mutable users bypass frozen content caches |
| Mesh content/device sharing | `MeshCache.host_mesh/device_mesh/invalidate` | Actual bytes/native identities/context/stream/constructor/grad key and independent GC leases |
| Convex mesh deduplication | `deduplicate` | Exact f32 equality, first vertex/velocity occurrence retained |
| Signed scale | `bake_scale` | Default repairs odd-reflection winding; `preserve_winding=true` matches raw signed SDF scale/index path |
| `create_mesh_heightfield` | `heightfield_mesh` | Actual ij top/bottom/side arrays from already-decoded heights; strict degenerate rejection |
| Solid/hollow mesh inertia | `mesh_mass` | Tetrahedral moments, negative volume correction, 8-wedge shell, density/COM/Steiner; CPU/Double |
| Analytic shape inertia | `primitive_mass` | Sphere/box/ellipsoid/capsule/cone/plain+barrel cylinder, shell subtraction and cone COM; plane/hfield/gaussian zero mass |
| Barrel inertia | `primitive_mass("cylinder",...)` | Actual 32-point Gauss–Legendre quadrature, Double nodes instead of NumPy evaluation |
| Signed inertia scale | `scale_mass` | Mass/COM/products of inertia; density is an additional multiplier |
| Source `transform_inertia` | `transform_inertia` | Rotation plus Steiner about origin: offset is actual transformed COM, not rigid translation |
| Canonical mass rigid transform | `transform_mass` | Rotates COM tensor and maps original COM by rotation+translation; avoids double Steiner |
| `verify_and_correct_inertia` | `correct_inertia` | Source threshold/order/bounds/symmetry/positive/triangle rules; bounded Jacobi eigensystem, explicit failure |
| Hull rank0/1/2 branches | `convex_hull` | Actual point/line fallback, planar monotone hull, uniform budget decimation, double winding; covariance/Jacobi replaces SVD |
| Hull rank3 branch | `convex_hull`, `native/hull.cpp` | Genuine reentrant Qhull Qt/TA/QJ retry, original vertices/remapping and outward winding |
| Canonical edge/dihedral/watertight topology | `mesh_topology` | Adjacency, angles, area/normals, boundary retention; first-occurrence labels instead of NumPy-sorted labels |
| Convex support acceleration | `convex_support` | Supporting planes/full rank/closed manifold/weld/CSR, optional1024 octahedral seeds; uncertified stays uncertified |
| Fully-concave filtering | `fully_concave_edges` | Canonical oriented rings, signed-volume/tolerance, angle normals and strict face-side tests |
| Box edge redundancy + greedy resolution | `absorb_edges` | Actual boxes/endpoint containment/directed graph/area tie breaks; exhaustive CPU pairs replace SAP, <=4096 candidates |
| Mesh collision-edge policy | `collision_edges` | Abs/relative defaults/exclusivity, negative-angle lazy fallback, zero-box disable, manifold removals over full boundary-preserving set, concavity |
| Mesh winding/parity/pseudo-normal distance | `HostMesh.sample_distances` | Genuine inline Warp CPU queries, accuracy2 and signed winding threshold correction |
| Current sparse texture cooking | `build_sparse_sdf`, `HostMesh.build_sparse_sdf`, `primitive_sparse_sdf` | Real coarse/center/9³ queries, linearity, exclusive addresses, slots, f32/u16/u8, paired-X packing |
| Primitive distance kernels | `primitive_distance` | Z-up sphere/box/capsule/cone/plain+barrel cylinder and source approximate ellipsoid |
| Native sparse texture upload | `SparseSdf.upload_textures` | Real CUDA coarse/subgrid arrays+objects and indirection Buffer; explicit context |
| Software sampling/gradient/voxel | `SparseSdf.sample/sample_gradient/sample_voxel` | Float interpolation/dequantization, outside extrapolation, sample-time margin, source coarse-gradient convention |
| Texture SDF marching cubes | `SparseSdf.isomesh` | Real256-case tables/source edges/clamp0.02..0.98/reversed faces; deterministic CPU order replaces atomic append |
| Legacy sparse/coarse SDF preparation | `build_legacy_sdf`, `HostMesh.build_legacy_sdf`, `primitive_legacy_sdf` | Actual floor/8 grid, occupied tiles,512 samples/tile, independent8³ coarse; margin baked once |
| Legacy occupied NanoVDB allocation/population | `open_tile_volume` | Actual native `wp_volume_from_tiles_host` + PNanoVDB `volume_store_f`; not silently densified |
| Dense NanoVDB | `open_volume` | Genuine all-tile host builder; separate from current texture path |
| Native volume query/conversion | `CookedField.sample_volume`, `LegacySdf.to_texture` | PNanoVDB world→index/linear reads; separate coarse, sparse occupancy/linearity, late coarse outlier replacement |
| Texture/volume resource lifetime | `open_texture`, `CookedField.upload/snapshot/close` | Real host Texture3D, CUDA array/object and host/device NanoVDB with private Context ownership |
| SDF persistent cache | `mesh_sdf_cache_key`, `primitive_sdf_cache_key`, `store_sdf_cache`, `load_sdf_cache`, `validate_storage` | Real SHA keys + typed binary/JSON, strict integrity checks; different format from upstream NPZ/BLAKE2b |

The old `HostMesh.metadata()` flags `convex_hull_computed:false` and
`inertia_computed:false` describe that Mesh resource constructor. They do not
say the separate mass/hull/SDF functions above are missing. New geometry
artifacts record the actual operation and resulting bytes independently.

## Inputs and command integration

Original `prepare_mesh(MeshRequest)`, async `mesh_artifact(request,output)` and
async `execute_cook(ExecuteRequest{request,adapter,warp_library,output})` remain.
MeshRequest fields are flat xyz `vertices`, triangle `indices`, `velocities`
(empty means zero), `groups` (empty or one int32/triangle), explicit
`bvh_constructor` sah/median, `bvh_leaf_size`1..64 and `support_winding_number`.
Coordinates are local; no units, triangulation or schema defaults are guessed.
The strict domain is3..4M vertices and1..4M triangles, finite representable f32,
no underflow to zero, repeated-index or Float32-collinear triangles.

The generalized CLI API is `decode_geometry_request(Json)->GeometryRequest`
and async `geometry_artifact(GeometryRequest{operation,parameters},output)->Json`.
It rejects unknown consumed fields and writes a fresh directory with actual
binary arrays and request/result/manifest hashes. No command creates CUDA.

| operation | parameters |
| --- | --- |
| `mesh-mass` | `{mesh,density,is_solid,thickness:Array[Double]}` scalar-broadcast or per vertex |
| `primitive-mass` | `{kind,scale:[3],density,is_solid,thickness:Double}` |
| `correct-inertia` | `{mass,inertia:[9],balance,bound_mass?,bound_inertia?}` |
| `scale-mass` | `{value:MassProperties,scale:[3],density}` |
| `transform-mass` | `{value:MassProperties,rotation:[9],translation:[3]}` |
| `scale` | `{mesh,scale:[3],preserve_winding?:Bool}` |
| `deduplicate` | `{mesh}` |
| `heightfield` | `{nx,ny,heights,extent_x,extent_y,center_x,center_y,ground_z}` |
| `topology` | `{mesh,lower_angle}` |
| `convex-support` | `{mesh}` |
| `convex-hull` | `{request:{vertices,max_vertices,rank_epsilon},adapter,qhull_library}` |
| `collision-edges` | `{mesh,options:CollisionEdgeOptions}` |
| `sparse-sdf` | `{mesh,options:SdfOptions,adapter,warp_library,cache_directory?:String}` |
| `primitive-sdf` | `{kind,scale:[3],options:SdfOptions,cache_directory?:String}` |
| `legacy-sdf` | `{mesh,options:LegacySdfOptions,adapter,warp_library}` |
| `legacy-texture` | `{mesh,options:LegacySdfOptions,texture_options:SdfOptions,adapter,warp_library}` |
| `primitive-legacy-sdf` | `{kind,scale:[3],options:LegacySdfOptions}` |
| `sample-sdf` | `{cache_directory,key,positions:flat_xyz,shape_margin,gradient:Bool}` |
| `isomesh` | `{cache_directory,key,isovalue,max_triangles}` |

`SdfOptions` explicitly requires `margin`, `narrow_band:[inner,outer]`,
`max_resolution`1..256, nullable `target_voxel_size`, `texture_format`
float32/uint16/uint8, `paired_samples`, `sign_method` auto/parity/winding/normal
for meshes, nullable `linearization_error` (0 disables). Callback/analytic
sources use diagnostic sign labels. Slot shape is xyz; texture shape is zyx,
x contiguous. Subgrid8 cells/9³ samples, texture<=256³. UInt padding remains
integer0. Quantization uses source Float subtract→reciprocal multiply→maxcode
multiply→truncate. Source Float/GPU numerical parity is still pending.

`LegacySdfOptions` requires `margin>0`, `shape_margin`, crossing-zero
`narrow_band`, `max_resolution`8..256 divisible8, nullable target voxel size.
Tiles store actual 8-aligned int32 xyz origins and tile,z,y,x Float32 values.
Coarse data is an independent8³ tile. Empty sparse inputs yield no sparse
owner: the pinned native host builder rejects zero points, so no dummy tile
is fabricated. Legacy→texture stores Float32 and keeps already-baked margin.

`CollisionEdgeOptions` requires lower/upper angle radians, box_absorption,
concave_filter, sign_method, nullable half_normal/half_normal_relative and
half_lateral/half_lateral_relative. Abs/relative choices are exclusive; defaults
are0.001/0.005*AABB diagonal. Negative lower angle returns None for lazy full
edges and forbids absorption. Zero extent disables absorption. Boundary and
nonmanifold edges survive as in Mesh._build_collision_edges, unlike upstream's
separate manifold-only remove_redundant_edges convenience return.

## Native ownership and caching

HostMesh IDs are CPU pointers; never pass them to CUDA. DeviceMesh IDs are
actual GPU descriptors on their retained context. Serialized decimal IDs are
evidence only and cannot be reused. Refit mutates unchanged allocations;
positions/velocities validate completely before mutation. Failed native calls
leave only close valid. No concurrent refit/use/close is supported.

Every HostMesh.share creates an independent opaque GC-finalized native lease.
Explicit close and GC release that token once. The last release synchronizes,
destroys device Mesh/BVH, device arrays, CPU Mesh, and Warp library; C++ vectors
remain live throughout. The loader unloads the adapter after native teardown,
then releases a **private** retained Context token. Abandoned clones do not
leave phantom MoonBit share counts.

Context.retain copies the actual dispatch shared Device/library owner and
thread affinity, without initializing another context. Closing the original
wrapper cannot invalidate independent resource tokens. If the context was
borrowed from an external creator, its true CUDA owner must still outlive every
lease. Calls/finalization follow the creating thread.

MeshCache keeps one lease and returns independent shares. Invalidate releases
only cache leases. Cached geometry/velocities are frozen; mutable surface
velocity uses an uncached owner. Optional `requires_grad=true` allocates actual
grad buffers before cache freezing. Reset/snapshot of grad storage is available;
Tape/backward kernels are not implied. Pinned mesh.h itself marks missing
adjoints, including point/velocity/face-normal gradient accumulation paths.

Texture and NanoVDB resources also retain private Context tokens. Volume
upload copies real NanoVDB bytes into an independently owned device allocation,
calls wp_volume_create_device(copy=false,owner=false), then frees the allocation
after descriptor destruction. Texture upload uses genuine CUDA-array copy and
object APIs; no CUDA descriptor struct is recreated. Populated NanoVDB optional
statistics/checksum metadata is not recomputed; binary metadata parity is not
claimed.

Persistent caches store bytes, never live handles. Load/upload checks shape,
SHA, finite f32, extents, unique slots/reserved bits/bounds and counts.
entry.json is published last in a fresh directory. Existing-entry races and
corruption fail explicitly; this differs from upstream log+miss/replace NPZ
behavior. Keys include format revision, explicit options and actual native
file identities. shape_margin is sample-time and absent. Bump the cache
revision when changing numerical/storage conventions.

## Remaining integration and verification boundaries

CPU/Double integration, Jacobi eigenbasis/rank versus NumPy SVD/eigvalsh,
quadrature, support ties, Qhull winding, FP32/FP64 reductions and GPU atomic
append order require differential testing. Rank0/1/2 hulls return actual
zero-volume raw arrays; HullMesh.prepare refuses to relabel them volumetric.
Strict mesh validation also rejects zero-height terrain wall degeneracies.

USD composition/custom-schema precedence, polygon triangulation, materials,
UV/normals/textures, asset/instance import, normalized row-major Heightfield→ij
decoding, Gaussian/TetMesh resources and complete Newton model/solver wiring
are separate source paths, not silently implemented by triangle cooking.
The original Python preserves those routes.

No hidden device/default is chosen. Automatic pre-SM90 paired-sample policy,
hardware-filter/finite-difference sampling, original Warp generated SDF/MC/SAP
launch scheduling, Tape/autodiff execution and complete packed TextureSDFData
model/kernel binding remain integration work. These use real native APIs or
source-generated kernels; they are not falsely labeled missing C capabilities.
Callers receive real owned IDs and slot arrays and must pack the genuine ABI.

## Native build and pending checks

native/CMakeLists.txt requires explicit genuine WARP_NATIVE_INCLUDE_DIR1.17.
It downloads/builds no dependency and runs no tool/runtime. POSIX builds include
field support. Optional MOONROBO_COOK_QHULL requires genuine Qhull2020.2 src
headers. Runtime reentrant ABI must match and report2020.2.r2020/08/31;
upstream qh_lib_check can terminate an incompatible process, so arbitrary
same-named libraries are not supported. Hull/field loaders reject Windows;
core host Mesh uses its platform loader. Only syntax checks were done, not a
native adapter build or library load.

Pending regression sources cover bytes/invalid inputs, tetrahedron moments,
shell/cone properties, canonical/origin transforms, reflection, zero-box edges,
quantized padding, sampling/gradient/extrapolation/margin and legacy tile/coarse
population. No test ran. Later native checks must cover GC leases, cache
invalidation with live clients, partial construction/context close, refits,
grad storage, Qhull rank/budget/retry, sparse topology, cache corruption/races,
device texture storage and pinned numerical/physics comparisons.

Copied MC tables retain NVIDIA copyright/SPDX notice and the bundled
[Warp license](THIRD_PARTY_LICENSE_WARP.txt). tools/import_mc_tables.mbtx only
regenerates literal tables from exact SHA-verified source text.
