///|
fn finite(x : Double) -> Bool {
  !x.is_nan() && !x.is_inf()
}

///|
fn floats(values : Array[Double]) -> Bytes raise {
  guard values.length() <= 12000000 else {
    fail("mesh scalar capacity exceeded")
  }
  let out : Array[Byte] = []
  for value in values {
    let f = Float::from_double(value)
    guard finite(value) && !f.is_nan() && !f.is_inf() && (value == 0 || f != 0) else {
      fail("nonfinite/overflow/underflow mesh float32 conversion")
    }
    let bits = f.reinterpret_as_uint()
    for i in 0..<4 {
      out.push(((bits >> (i * 8)) & 255U).to_byte())
    }
  }
  Bytes::from_array(out)
}

///|
fn ints(values : Array[Int32]) -> Bytes {
  let out : Array[Byte] = []
  for value in values {
    let bits = value.reinterpret_as_uint()
    for i in 0..<4 {
      out.push(((bits >> (i * 8)) & 255U).to_byte())
    }
  }
  Bytes::from_array(out)
}

///|
fn checked_points(
  vertices : Array[Double],
  indices : Array[Int32],
) -> Bytes raise {
  guard vertices.length() >= 9 &&
    vertices.length() % 3 == 0 &&
    vertices.length() <= 12000000 else {
    fail("mesh requires 3..4000000 explicit vec3 vertices")
  }
  let points = floats(vertices)
  let nv = vertices.length() / 3
  guard indices.length() >= 3 &&
    indices.length() % 3 == 0 &&
    indices.length() <= 12000000 else {
    fail(
      "mesh requires 1..4000000 triangles; polygon triangulation is not inferred",
    )
  }
  guard indices.all(i => i >= 0 && i < nv) else {
    fail("mesh triangle index outside vertex buffer")
  }
  for i in 0..<(indices.length() / 3) {
    let a = indices[i * 3]
    let b = indices[i * 3 + 1]
    let c = indices[i * 3 + 2]
    guard a != b && b != c && a != c else {
      fail("mesh triangle has repeated indices")
    }
    // Validate the actual float32 coordinates, rather than the uncast input.
    let ax = Float::from_double(vertices[a * 3]).to_double()
    let ay = Float::from_double(vertices[a * 3 + 1]).to_double()
    let az = Float::from_double(vertices[a * 3 + 2]).to_double()
    let ux = Float::from_double(vertices[b * 3]).to_double() - ax
    let uy = Float::from_double(vertices[b * 3 + 1]).to_double() - ay
    let uz = Float::from_double(vertices[b * 3 + 2]).to_double() - az
    let vx = Float::from_double(vertices[c * 3]).to_double() - ax
    let vy = Float::from_double(vertices[c * 3 + 1]).to_double() - ay
    let vz = Float::from_double(vertices[c * 3 + 2]).to_double() - az
    guard ux * vy - uy * vx != 0 ||
      uy * vz - uz * vy != 0 ||
      uz * vx - ux * vz != 0 else {
      fail("mesh triangle is degenerate after float32 conversion")
    }
  }
  points
}

///|
/// Host-only validation/packing; no native library or cooking is invoked.
pub fn prepare_mesh(request : MeshRequest) -> PreparedMesh raise {
  guard (
      request.bvh_constructor == "sah" || request.bvh_constructor == "median"
    ) &&
    request.bvh_leaf_size >= 1 &&
    request.bvh_leaf_size <= 64 else {
    fail("explicit host SAH/median constructor and leaf size 1..64 required")
  }
  let points = checked_points(request.vertices, request.indices)
  let nv = request.vertices.length() / 3
  let nt = request.indices.length() / 3
  guard request.velocities.is_empty() ||
    request.velocities.length() == request.vertices.length() else {
    fail("velocity vec3 cardinality differs from points")
  }
  guard request.groups.is_empty() || request.groups.length() == nt else {
    fail("groups must contain one int32 per triangle")
  }
  {
    points,
    indices: ints(request.indices),
    velocities: floats(
      if request.velocities.is_empty() {
        Array::make(request.vertices.length(), 0.0)
      } else {
        request.velocities
      },
    ),
    groups: ints(request.groups),
    vertex_count: nv,
    triangle_count: nt,
    bvh_constructor: request.bvh_constructor,
    bvh_leaf_size: request.bvh_leaf_size,
    support_winding_number: request.support_winding_number,
  }
}

///|
pub fn PreparedMesh::metadata(self : PreparedMesh) -> Json {
  {
    "format": "moonrobo.local-triangle-mesh-bytes.v1",
    "vertex_count": Json(self.vertex_count),
    "triangle_count": Json(self.triangle_count),
    "points_sha256": Json(@artifacts.sha256(self.points)),
    "velocities_sha256": Json(@artifacts.sha256(self.velocities)),
    "indices_sha256": Json(@artifacts.sha256(self.indices)),
    "groups_sha256": Json(@artifacts.sha256(self.groups)),
    "points_dtype": "vec3f",
    "indices_dtype": "int32",
    "byte_order": "little",
    "vertex_space": "explicit-local-unscaled",
    "bvh_constructor": Json(self.bvh_constructor),
    "bvh_leaf_size": Json(self.bvh_leaf_size),
    "support_winding_number": Json(self.support_winding_number),
    "native_mesh_created": false,
    "convex_hull_computed": false,
    "inertia_computed": false,
    "full_newton_cooking_complete": false,
  }
}
