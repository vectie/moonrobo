///|
fn word(bytes : Bytes, i : Int32) -> UInt32 {
  bytes[i].to_uint() |
  (bytes[i + 1].to_uint() << 8) |
  (bytes[i + 2].to_uint() << 16) |
  (bytes[i + 3].to_uint() << 24)
}

///|
pub fn PreparedMesh::vertices(self : PreparedMesh) -> Array[Double] {
  Array::makei(self.points.length() / 4, i => {
    Float::reinterpret_from_int(word(self.points, i * 4).to_int()).to_double()
  })
}

///|
pub fn PreparedMesh::triangles(self : PreparedMesh) -> Array[Int32] {
  Array::makei(self.indices.length() / 4, i => {
    word(self.indices, i * 4).reinterpret_as_int()
  })
}

///|
fn point(v : Array[Double], i : Int32) -> @geo.Vec3 {
  @geo.vec3(v[i * 3], v[i * 3 + 1], v[i * 3 + 2])
}

///|
fn push_point(v : Array[Double], p : @geo.Vec3) -> Unit {
  v.push(p.x)
  v.push(p.y)
  v.push(p.z)
}

///|
fn template(
  mesh : PreparedMesh,
  v : Array[Double],
  idx : Array[Int32],
) -> MeshRequest {
  {
    vertices: v,
    indices: idx,
    velocities: Array::makei(mesh.velocities.length() / 4, i => {
      Float::reinterpret_from_int(word(mesh.velocities, i * 4).to_int()).to_double()
    }),
    groups: Array::makei(mesh.groups.length() / 4, i => {
      word(mesh.groups, i * 4).reinterpret_as_int()
    }),
    bvh_constructor: mesh.bvh_constructor,
    bvh_leaf_size: mesh.bvh_leaf_size,
    support_winding_number: mesh.support_winding_number,
  }
}

///|
/// Bake explicit signed local scale. Odd reflections reverse each triangle
/// to retain outward winding. Velocity vectors receive the same linear map.
/// preserve_winding=true implements the SDF source's raw signed scale path:
/// indices stay unchanged and the sign query resolves the reversed volume.
pub fn bake_scale(
  mesh : PreparedMesh,
  scale : Array[Double],
  preserve_winding~ : Bool = false,
) -> PreparedMesh raise {
  guard scale.length() == 3 && scale.all(x => finite(x) && x != 0) else {
    fail("nonzero finite xyz scale required")
  }
  let v = mesh.vertices()
  let idx = mesh.triangles()
  for i in 0..<v.length() {
    v[i] *= scale[i % 3]
  }
  if !preserve_winding && ((scale[0] < 0) != (scale[1] < 0)) != (scale[2] < 0) {
    for i in 0..<mesh.triangle_count {
      let b = idx[i * 3 + 1]
      idx[i * 3 + 1] = idx[i * 3 + 2]
      idx[i * 3 + 2] = b
    }
  }
  let request = template(mesh, v, idx)
  for i in 0..<request.velocities.length() {
    request.velocities[i] *= scale[i % 3]
  }
  prepare_mesh(request)
}

///|
pub(all) struct HeightfieldRequest {
  nx : Int32
  ny : Int32
  heights : Array[Double]
  extent_x : Double
  extent_y : Double
  center_x : Double
  center_y : Double
  ground_z : Double
} derive(FromJson, ToJson)

///|
/// Pinned create_mesh_heightfield ij ordering, top/bottom/side winding. Input
/// height data is already decoded metres, not normalized Heightfield.data.
pub fn heightfield_mesh(r : HeightfieldRequest) -> PreparedMesh raise {
  guard r.nx >= 2 &&
    r.ny >= 2 &&
    r.nx <= 1000 &&
    r.ny <= 1000 &&
    r.heights.length() == r.nx * r.ny &&
    r.extent_x > 0 &&
    r.extent_y > 0 &&
    [r.extent_x, r.extent_y, r.center_x, r.center_y, r.ground_z].all(finite) &&
    r.heights.all(finite) else {
    fail("invalid heightfield dimensions/extents/samples")
  }
  let n = r.nx * r.ny
  let v = []
  let idx = []
  for layer in 0..<2 {
    for i in 0..<r.nx {
      for j in 0..<r.ny {
        v.push(
          -r.extent_x / 2 +
          r.extent_x * i.to_double() / (r.nx - 1).to_double() +
          r.center_x,
        )
        v.push(
          -r.extent_y / 2 +
          r.extent_y * j.to_double() / (r.ny - 1).to_double() +
          r.center_y,
        )
        v.push(if layer == 0 { r.heights[i * r.ny + j] } else { r.ground_z })
      }
    }
  }
  fn tri(a : Int32, b : Int32, c : Int32) -> Unit {
    idx.push(a)
    idx.push(b)
    idx.push(c)
  }
  for i in 0..<(r.nx - 1) {
    for j in 0..<(r.ny - 1) {
      let a = i * r.ny + j
      let b = a + 1
      let c = a + r.ny
      let d = c + 1
      tri(a, c, b)
      tri(b, c, d)
    }
  }
  for i in 0..<(r.nx - 1) {
    for j in 0..<(r.ny - 1) {
      let a = n + i * r.ny + j
      let b = a + 1
      let c = a + r.ny
      let d = c + 1
      tri(a, b, c)
      tri(b, d, c)
    }
  }
  fn wall(a : Int32, b : Int32, flip : Bool) -> Unit {
    if flip {
      tri(a, b, a + n)
      tri(b, b + n, a + n)
    } else {
      tri(a, a + n, b)
      tri(b, a + n, b + n)
    }
  }
  for i in 0..<(r.nx - 1) {
    wall(i * r.ny, (i + 1) * r.ny, false)
  }
  for i in 0..<(r.nx - 1) {
    wall(i * r.ny + r.ny - 1, (i + 1) * r.ny + r.ny - 1, true)
  }
  for j in 0..<(r.ny - 1) {
    wall(j, j + 1, true)
  }
  for j in 0..<(r.ny - 1) {
    wall((r.nx - 1) * r.ny + j, (r.nx - 1) * r.ny + j + 1, false)
  }
  prepare_mesh({
    vertices: v,
    indices: idx,
    velocities: [],
    groups: [],
    bvh_constructor: "sah",
    bvh_leaf_size: 4,
    support_winding_number: false,
  })
}

///|
/// Exact float32 coordinate deduplication retaining first occurrence order,
/// matching builder._deduplicate_convex_collision_mesh support tie order.
pub fn deduplicate(mesh : PreparedMesh) -> PreparedMesh raise {
  let v = mesh.vertices()
  let idx = mesh.triangles()
  let seen : Map[(UInt32, UInt32, UInt32), Int32] = {}
  let remap = []
  let unique = []
  let velocities = []
  for i in 0..<mesh.vertex_count {
    // IEEE -0 and +0 compare equal in numpy.unique(axis=0).
    let p = point(v, i)
    let key = (
      if p.x == 0 {
        0U
      } else {
        word(mesh.points, i * 12)
      },
      if p.y == 0 {
        0U
      } else {
        word(mesh.points, i * 12 + 4)
      },
      if p.z == 0 {
        0U
      } else {
        word(mesh.points, i * 12 + 8)
      },
    )
    if seen.get(key) is Some(index) {
      remap.push(index)
    } else {
      let index = unique.length() / 3
      seen[key] = index
      remap.push(index)
      push_point(unique, p)
      for k in 0..<3 {
        velocities.push(
          Float::reinterpret_from_int(
            word(mesh.velocities, i * 12 + k * 4).to_int(),
          ).to_double(),
        )
      }
    }
  }
  for i in 0..<idx.length() {
    idx[i] = remap[idx[i]]
  }
  let r = template(mesh, unique, idx)
  prepare_mesh({ ..r, velocities, })
}
