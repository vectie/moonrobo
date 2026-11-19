///|
#borrow(mesh, values)
extern "c" fn native_velocities(mesh : NativeMesh, values : Bytes) -> Unit = "moonrobo_mesh_velocities"

///|
#borrow(mesh)
extern "c" fn native_gradients(mesh : NativeMesh, operation : Int32) -> Unit = "moonrobo_mesh_gradients"

///|
#borrow(mesh)
extern "c" fn native_gradient_snapshot(
  mesh : NativeMesh,
  device : Int32,
  velocity : Int32,
  size : Int32,
) -> Bytes = "moonrobo_mesh_gradient_snapshot"

///|
/// In-place surface-velocity update: same borrowed vector allocation, no
/// topology change. Mutable meshes deliberately bypass frozen content caches.
pub fn HostMesh::refit_velocities(
  self : HostMesh,
  values : Array[Double],
) -> Unit raise {
  self.check()
  guard !self.0.frozen.val &&
    values.length() == self.0.prepared.vertex_count * 3 else {
    fail("uncached mesh and unchanged velocity span required")
  }
  let bytes = floats(values)
  native_velocities(self.0.native, bytes)
  self.check()
  self.0.velocity_bytes.val = bytes
}

///|
/// Allocates real zeroed point/velocity adjoint arrays and attaches their
/// pointers to genuine Warp array_t descriptors. This is storage, not a Tape
/// or differentiation claim: pinned mesh.h itself marks several mesh adjoints
/// MISSINGADJOINT. Creation is explicit and forbidden on a frozen cache entry.
pub fn HostMesh::enable_gradients(self : HostMesh) -> Unit raise {
  self.check()
  guard !self.0.frozen.val && !self.0.gradients.val else {
    fail("fresh uncached gradient storage required")
  }
  native_gradients(self.0.native, 0)
  self.check()
  self.0.gradients.val = true
}

///|
pub fn HostMesh::zero_gradients(self : HostMesh) -> Unit raise {
  self.check()
  guard self.0.gradients.val else { fail("mesh has no gradient storage") }
  native_gradients(self.0.native, 1)
  self.check()
}

///|
pub fn HostMesh::gradient_snapshot(
  self : HostMesh,
  velocity~ : Bool = false,
) -> Bytes raise {
  self.check()
  guard self.0.gradients.val else { fail("mesh has no gradient storage") }
  let bytes = native_gradient_snapshot(
    self.0.native,
    0,
    if velocity {
      1
    } else {
      0
    },
    self.0.prepared.vertex_count * 12,
  )
  self.check()
  bytes
}

///|
pub fn DeviceMesh::refit_velocities(
  self : DeviceMesh,
  values : Array[Double],
) -> Unit raise {
  self.0.context.synchronize()
  self.0.host.refit_velocities(values)
}

///|
pub fn DeviceMesh::enable_gradients(self : DeviceMesh) -> Unit raise {
  self.0.context.synchronize()
  self.0.host.enable_gradients()
}

///|
pub fn DeviceMesh::zero_gradients(self : DeviceMesh) -> Unit raise {
  self.0.context.synchronize()
  self.0.host.zero_gradients()
}

///|
pub fn DeviceMesh::gradient_snapshot(
  self : DeviceMesh,
  velocity~ : Bool = false,
) -> Bytes raise {
  self.0.host.check()
  guard self.0.host.0.gradients.val else {
    fail("mesh has no gradient storage")
  }
  self.0.context.synchronize()
  let bytes = native_gradient_snapshot(
    self.0.host.0.native,
    1,
    if velocity {
      1
    } else {
      0
    },
    self.0.host.0.prepared.vertex_count * 12,
  )
  self.0.host.check()
  bytes
}
