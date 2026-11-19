///|
pub struct MeshCache(MeshCacheOwners)

///|
struct MeshCacheOwners {
  host : Map[String, HostMesh]
  device : Map[String, DeviceMesh]
}

///|
pub fn MeshCache::new() -> MeshCache {
  MeshCache({ host: {}, device: {}, })
}

///|
fn geometry_key(mesh : PreparedMesh) -> String {
  @artifacts.sha256(@utf8.encode(mesh.metadata().stringify()))
}

///|
/// Actual bytes, geometry flags, constructors and native file identities form
/// the key. Cached geometry cannot be refitted; invalidate+new preparation is
/// required, while existing consumer leases remain valid.
pub async fn MeshCache::host_mesh(
  self : MeshCache,
  adapter : String,
  library : String,
  mesh : PreparedMesh,
  requires_grad~ : Bool = false,
) -> HostMesh {
  let ad = explicit_file(adapter)
  let lib = explicit_file(library)
  let a = @artifacts.sha256(@fs.read_file(ad).binary())
  let b = @artifacts.sha256(@fs.read_file(lib).binary())
  let key = geometry_key(mesh) +
    ":" +
    ad +
    ":" +
    a +
    ":" +
    lib +
    ":" +
    b +
    ":grad=" +
    requires_grad.to_string()
  if self.0.host.get(key) is Some(value) {
    return value.share()
  }
  let value = open_host_mesh(ad, lib, mesh)
  errdefer value.close()
  if requires_grad {
    value.enable_gradients()
  }
  guard a == @artifacts.sha256(@fs.read_file(ad).binary()) &&
    b == @artifacts.sha256(@fs.read_file(lib).binary()) else {
    fail("native mesh cache inputs changed during construction")
  }
  value.0.frozen.val = true
  self.0.host[key] = value
  value.share()
}

///|
pub async fn MeshCache::device_mesh(
  self : MeshCache,
  adapter : String,
  library : String,
  mesh : PreparedMesh,
  context : @dispatch.Context,
  options : DeviceMeshOptions,
  requires_grad~ : Bool = false,
) -> DeviceMesh {
  let ad = explicit_file(adapter)
  let lib = explicit_file(library)
  let a = @artifacts.sha256(@fs.read_file(ad).binary())
  let b = @artifacts.sha256(@fs.read_file(lib).binary())
  let identity = context.pointer().to_string() +
    ":" +
    context.stream().to_string()
  let key = geometry_key(mesh) +
    ":" +
    ad +
    ":" +
    a +
    ":" +
    lib +
    ":" +
    b +
    ":" +
    identity +
    ":" +
    options.to_json().stringify() +
    ":grad=" +
    requires_grad.to_string()
  if self.0.device.get(key) is Some(value) {
    ignore(value.id())
    return value.share()
  }
  let value = open_device_mesh(ad, lib, mesh, context, options)
  errdefer value.close()
  if requires_grad {
    value.enable_gradients()
  }
  guard a == @artifacts.sha256(@fs.read_file(ad).binary()) &&
    b == @artifacts.sha256(@fs.read_file(lib).binary()) else {
    fail("native device cache inputs changed during construction")
  }
  value.0.host.0.frozen.val = true
  self.0.device[key] = value
  value.share()
}

///|
/// Releases the cache's leases only; consumer leases retain the native
/// resources. Context and true external CUDA owner must outlive every lease.
pub fn MeshCache::invalidate(self : MeshCache) -> Unit raise {
  for value in self.0.host.values() {
    value.close()
  }
  self.0.host.clear()
  for value in self.0.device.values() {
    value.close()
  }
  self.0.device.clear()
}
