///|
priv type NativeMesh

///|
#borrow(adapter, library, points, velocities, indices, groups)
extern "c" fn native_open(
  adapter : Bytes,
  library : Bytes,
  points : Bytes,
  velocities : Bytes,
  indices : Bytes,
  groups : Bytes,
  constructor_type : Int32,
  leaf : Int32,
  winding : Int32,
) -> NativeMesh = "moonrobo_host_mesh_open"

///|
#borrow(mesh)
extern "c" fn native_error(mesh : NativeMesh) -> Bytes = "moonrobo_host_mesh_error"

///|
#borrow(mesh)
extern "c" fn native_id(mesh : NativeMesh) -> UInt64 = "moonrobo_host_mesh_id"

///|
#borrow(mesh, points)
extern "c" fn native_refit(mesh : NativeMesh, points : Bytes) -> Unit = "moonrobo_host_mesh_refit"

///|
#borrow(mesh)
extern "c" fn native_close(mesh : NativeMesh) -> Unit = "moonrobo_host_mesh_close"

///|
#borrow(mesh)
extern "c" fn native_share(mesh : NativeMesh) -> NativeMesh = "moonrobo_host_mesh_share"

///|
/// CPU-only Warp resource. The ID is a host resource address, unusable as a
/// CUDA mesh or a convex-hull/support-graph resource. Keep this owner alive.
pub struct HostMesh(HostMeshOwners)

///|
struct HostMeshOwners {
  native : NativeMesh
  prepared : PreparedMesh
  point_bytes : Ref[Bytes]
  velocity_bytes : Ref[Bytes]
  closed : Ref[Bool]
  frozen : Ref[Bool]
  gradients : Ref[Bool]
}

///|
fn HostMesh::check(self : HostMesh) -> Unit raise {
  guard !self.0.closed.val else { fail("host mesh is closed") }
  let error = @utf8.decode(native_error(self.0.native))
  guard error.is_empty() else { fail(error) }
}

///|
/// Explicit native execution. Creates the genuine Warp host mesh/BVH and owns
/// a copied geometry buffer. No wp_init/CUDA/JIT or Python entry point is called.
pub fn open_host_mesh(
  adapter : String,
  warp_library : String,
  prepared : PreparedMesh,
) -> HostMesh raise {
  guard !adapter.is_empty() &&
    !warp_library.is_empty() &&
    !adapter.contains("\u{0}") &&
    !warp_library.contains("\u{0}") else {
    fail("explicit NUL-free adapter/Warp paths required")
  }
  let mesh = native_open(
    @utf8.encode(adapter),
    @utf8.encode(warp_library),
    prepared.points,
    prepared.velocities,
    prepared.indices,
    prepared.groups,
    if prepared.bvh_constructor == "sah" {
      0
    } else {
      1
    },
    prepared.bvh_leaf_size,
    if prepared.support_winding_number {
      1
    } else {
      0
    },
  )
  let owner = HostMesh({
    native: mesh,
    prepared,
    point_bytes: Ref(prepared.points),
    velocity_bytes: Ref(prepared.velocities),
    closed: Ref(false),
    frozen: Ref(false),
    gradients: Ref(false),
  })
  try {
    owner.check()
    guard native_id(mesh) != 0UL else { fail("native host mesh ID is zero") }
  } catch {
    error => {
      owner.close()
      raise error
    }
  }
  owner
}

///|
pub fn HostMesh::id(self : HostMesh) -> UInt64 raise {
  self.check()
  native_id(self.0.native)
}

///|
/// Refit updates positions in the same native allocation and unchanged
/// topology. Invalid positions fail before updating any native points.
pub fn HostMesh::refit_points(
  self : HostMesh,
  vertices : Array[Double],
) -> Unit raise {
  self.check()
  guard !self.0.frozen.val else {
    fail(
      "cached geometry is immutable; invalidate and prepare a new content key",
    )
  }
  guard vertices.length() == self.0.prepared.vertex_count * 3 else {
    fail("refit cannot change vertex count")
  }
  let indices = []
  for i in 0..<(self.0.prepared.indices.length() / 4) {
    let b = i * 4
    let bytes = self.0.prepared.indices
    indices.push(
      (bytes[b].to_uint() |
      (bytes[b + 1].to_uint() << 8) |
      (bytes[b + 2].to_uint() << 16) |
      (bytes[b + 3].to_uint() << 24)).reinterpret_as_int(),
    )
  }
  let points = checked_points(vertices, indices)
  native_refit(self.0.native, points)
  self.check()
  self.0.point_bytes.val = points
}

///|
pub fn HostMesh::metadata(self : HostMesh) -> Json raise {
  self.check()
  {
    "format": "moonrobo.warp-host-mesh-resource.v1",
    "host_mesh_id_decimal": Json(self.id().to_string()),
    "prepared": self.0.prepared.metadata(),
    "current_points_sha256": Json(@artifacts.sha256(self.0.point_bytes.val)),
    "current_velocities_sha256": Json(
      @artifacts.sha256(self.0.velocity_bytes.val),
    ),
    "gradient_storage_allocated": Json(self.0.gradients.val),
    "backward_kernels_executed": false,
    "native_mesh_created": true,
    "warp_version": "1.17.0",
    "device": "cpu",
    "resource_id_serializable_for_reuse": false,
    "gpu_mesh_created": false,
    "convex_hull_computed": false,
    "inertia_computed": false,
    "full_newton_cooking_complete": false,
  }
}

///|
/// Terminal and idempotent; callers must release every dependent native
/// pointer/user before close. No device context is involved or owned.
pub fn HostMesh::close(self : HostMesh) -> Unit {
  if !self.0.closed.val {
    native_close(self.0.native)
    self.0.closed.val = true
  }
}

///|
/// Independent close token retaining the same actual resource. Used by caches
/// so eviction never invalidates a still-owned model's resource ID.
pub fn HostMesh::share(self : HostMesh) -> HostMesh raise {
  self.check()
  let lease = HostMesh({
    ..self.0,
    native: native_share(self.0.native),
    closed: Ref(false),
  })
  errdefer lease.close()
  lease.check()
  lease
}

///|
#borrow(mesh)
extern "c" fn native_make_device(
  mesh : NativeMesh,
  context : UInt64,
  stream : UInt64,
  constructor_type : Int32,
  leaf : Int32,
) -> Unit = "moonrobo_mesh_make_device"

///|
#borrow(mesh)
extern "c" fn native_device_id(mesh : NativeMesh) -> UInt64 = "moonrobo_mesh_device_id"

///|
#borrow(mesh)
#owned(context)
extern "c" fn native_context_owner(
  mesh : NativeMesh,
  context : @dispatch.Context,
) -> Unit = "moonrobo_mesh_context_owner"

///|
#borrow(mesh, points)
extern "c" fn native_sample(
  mesh : NativeMesh,
  points : Bytes,
  mode : Int32,
  maximum : Float,
  threshold : Float,
) -> Bytes = "moonrobo_mesh_sample"

///|
/// Genuine Warp CPU query entry points, same sign/accuracy semantics as pinned
/// get_distance_to_mesh{,_parity,_normal}. Returned values are signed metres.
pub fn HostMesh::sample_distances(
  self : HostMesh,
  points : Array[Double],
  sign_method : String,
  max_distance : Double,
  winding_threshold : Double,
) -> Array[Double] raise {
  self.check()
  guard points.length() % 3 == 0 &&
    finite(max_distance) &&
    max_distance > 0 &&
    finite(winding_threshold) else {
    fail("invalid SDF query dimensions/range")
  }
  let mode = match sign_method {
    "winding" => 0
    "parity" => 1
    "normal" => 2
    _ => fail("resolved winding/parity/normal sign method required")
  }
  let bytes = floats(points)
  let max_f = Float::from_double(max_distance)
  let threshold = Float::from_double(winding_threshold)
  guard !max_f.is_inf() && max_f > 0 && !threshold.is_inf() else {
    fail("SDF query parameters overflow float32")
  }
  if points.is_empty() {
    return []
  }
  let values = native_sample(self.0.native, bytes, mode, max_f, threshold)
  self.check()
  guard values.length() == points.length() / 3 * 4 else {
    fail("native SDF query output cardinality differs")
  }
  let result = Array::makei(values.length() / 4, i => {
    Float::reinterpret_from_int(word(values, i * 4).to_int()).to_double()
  })
  guard result.all(finite) else { fail("nonfinite native SDF result") }
  result
}

///|
pub(all) struct DeviceMeshOptions {
  bvh_constructor : String
  bvh_leaf_size : Int32
} derive(FromJson, ToJson)

///|
pub struct DeviceMesh(DeviceMeshOwners)

///|
struct DeviceMeshOwners {
  host : HostMesh
  context : @dispatch.Context
  options : DeviceMeshOptions
}

///|
/// Explicit native execution. Owns real device points/velocity/index/group
/// allocations and Warp GPU Mesh/BVH, retaining the exact borrowed Context.
/// A CPU accelerator is also retained for the same geometry/query provenance.
pub fn open_device_mesh(
  adapter : String,
  warp_library : String,
  prepared : PreparedMesh,
  context : @dispatch.Context,
  options : DeviceMeshOptions,
) -> DeviceMesh raise {
  let kind = match options.bvh_constructor {
    "sah" => 0
    "median" => 1
    "lbvh" => 2
    "cubql" => -1
    _ => fail("unknown device BVH constructor")
  }
  guard options.bvh_leaf_size >= 0 &&
    options.bvh_leaf_size <= 64 &&
    (kind == -1 || options.bvh_leaf_size >= 1) else {
    fail("invalid explicit device leaf size")
  }
  let host = open_host_mesh(adapter, warp_library, prepared)
  errdefer host.close()
  let retained = context.retain()
  errdefer retained.close()
  native_context_owner(host.0.native, retained.retain())
  retained.synchronize()
  native_make_device(
    host.0.native,
    retained.pointer(),
    retained.stream(),
    kind,
    options.bvh_leaf_size,
  )
  host.check()
  guard native_device_id(host.0.native) != 0UL else {
    fail("genuine device Mesh ID is zero")
  }
  DeviceMesh({ host, context: retained, options, })
}

///|
pub fn DeviceMesh::id(self : DeviceMesh) -> UInt64 raise {
  self.0.host.check()
  ignore(self.0.context.pointer())
  native_device_id(self.0.host.0.native)
}

///|
pub fn DeviceMesh::refit_points(
  self : DeviceMesh,
  points : Array[Double],
) -> Unit raise {
  self.0.context.synchronize()
  self.0.host.refit_points(points)
}

///|
pub fn DeviceMesh::metadata(self : DeviceMesh) -> Json raise {
  {
    "format": "moonrobo.warp-device-mesh-resource.v1",
    "device_mesh_id_decimal": Json(self.id().to_string()),
    "context_decimal": Json(self.0.context.pointer().to_string()),
    "options": self.0.options.to_json(),
    "host_accelerator": self.0.host.metadata(),
    "gpu_mesh_created": true,
    "requires_grad": Json(self.0.host.0.gradients.val),
    "resource_id_serializable_for_reuse": false,
    "full_newton_cooking_complete": false,
  }
}

///|
pub fn DeviceMesh::share(self : DeviceMesh) -> DeviceMesh raise {
  let context = self.0.context.retain()
  errdefer context.close()
  DeviceMesh({ ..self.0, host: self.0.host.share(), context, })
}

///|
pub fn DeviceMesh::close(self : DeviceMesh) -> Unit raise {
  if !self.0.host.0.closed.val {
    self.0.context.synchronize()
    self.0.host.close()
    self.0.context.close()
  }
}
