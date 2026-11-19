///|
pub(all) struct MassProperties {
  mass : Double
  com : Array[Double]
  inertia : Array[Double]
  volume : Double
} derive(ToJson, FromJson)

///|
fn valid_mass(m : MassProperties) -> MassProperties raise {
  guard m.com.length() == 3 &&
    m.inertia.length() == 9 &&
    [m.mass, m.volume].all(finite) &&
    m.com.all(finite) &&
    m.inertia.all(finite) else {
    fail("mass/inertia dimensions or finite range invalid")
  }
  m
}

///|
fn triangle_moments(
  a : @geo.Vec3,
  b : @geo.Vec3,
  c : @geo.Vec3,
  sum : Array[Double],
) -> Unit {
  let volume = a.dot(b.cross(c)) / 6.0
  sum[0] += volume
  let p = [a.x, a.y, a.z]
  let q = [b.x, b.y, b.z]
  let r = [c.x, c.y, c.z]
  for i in 0..<3 {
    sum[1 + i] += volume * (p[i] + q[i] + r[i]) / 4.0
    for j in 0..<3 {
      sum[4 + i * 3 + j] += volume /
        10.0 *
        (p[i] * p[j] + q[i] * q[j] + r[i] * r[j]) +
        volume /
        20.0 *
        (
          p[i] * q[j] +
          q[i] * p[j] +
          p[i] * r[j] +
          r[i] * p[j] +
          q[i] * r[j] +
          r[i] * q[j]
        )
    }
  }
}

///|
/// Actual pinned tetrahedron first/second moments and hollow eight-triangle
/// wedge integration. CPU/Double accumulation replaces Warp tiled float32;
/// numerical parity remains unverified. thickness is per-vertex half-offset.
pub fn mesh_mass(
  mesh : PreparedMesh,
  density : Double,
  is_solid : Bool,
  thickness : Array[Double],
) -> MassProperties raise {
  guard finite(density) &&
    density >= 0 &&
    (
      is_solid ||
      thickness.length() == 1 ||
      thickness.length() == mesh.vertex_count
    ) &&
    thickness.all(t => finite(t) && t >= 0) else {
    fail("invalid mesh density/thickness")
  }
  let v = mesh.vertices()
  let idx = mesh.triangles()
  let sum = Array::make(13, 0.0)
  for tri in 0..<mesh.triangle_count {
    let i = idx[tri * 3]
    let j = idx[tri * 3 + 1]
    let k = idx[tri * 3 + 2]
    let a = point(v, i)
    let b = point(v, j)
    let c = point(v, k)
    if is_solid {
      triangle_moments(a, b, c, sum)
    } else {
      let normal = b.sub(a).cross(c.sub(a))
      let length = normal.length()
      guard length > 0 && finite(length) else {
        fail("hollow mesh has invalid face normal")
      }
      let n = normal.scale(-1.0 / length)
      let ta = if thickness.length() == 1 { thickness[0] } else { thickness[i] }
      let tb = if thickness.length() == 1 { thickness[0] } else { thickness[j] }
      let tc = if thickness.length() == 1 { thickness[0] } else { thickness[k] }
      let a0 = a.sub(n.scale(ta))
      let a1 = a.add(n.scale(ta))
      let b0 = b.sub(n.scale(tb))
      let b1 = b.add(n.scale(tb))
      let c0 = c.sub(n.scale(tc))
      let c1 = c.add(n.scale(tc))
      for
        (x, y, z) in [
          (a0, b0, c0),
          (b0, c1, c0),
          (b0, b1, c1),
          (b0, a1, b1),
          (b0, a0, a1),
          (b1, a1, c1),
          (a1, a0, c0),
          (a1, c0, c1),
        ] {
        triangle_moments(x, y, z, sum)
      }
    }
  }
  if sum[0] < 0 {
    for i in 0..<13 {
      sum[i] = -sum[i]
    }
  }
  let volume = sum[0]
  let mass = density * volume
  let com = Array::makei(3, i => {
    if volume > 0 {
      sum[1 + i] / volume
    } else {
      sum[1 + i]
    }
  })
  let trace = (sum[4] + sum[8] + sum[12]) * density
  let radius = com[0] * com[0] + com[1] * com[1] + com[2] * com[2]
  let inertia = Array::makei(9, k => {
    let i = k / 3
    let j = k % 3
    (if i == j { trace } else { 0.0 }) -
    sum[4 + k] * density -
    mass * ((if i == j { radius } else { 0.0 }) - com[i] * com[j])
  })
  valid_mass({ mass, com, inertia, volume, })
}

///|
/// Signed nonuniform scale of an existing mesh's mass properties. Absolute
/// determinant controls mass; signed scale controls COM/products of inertia.
pub fn scale_mass(
  value : MassProperties,
  scale : Array[Double],
  density : Double,
) -> MassProperties raise {
  ignore(valid_mass(value))
  guard scale.length() == 3 &&
    scale.all(finite) &&
    finite(density) &&
    density >= 0 else {
    fail("invalid mass scale/density")
  }
  let ratio = (scale[0] * scale[1] * scale[2]).abs() * density
  let i = value.inertia
  let second = [
    (i[4] + i[8] - i[0]) / 2,
    (i[0] + i[8] - i[4]) / 2,
    (i[0] + i[4] - i[8]) / 2,
  ]
  let diag = [
    (scale[1] * scale[1] * second[1] + scale[2] * scale[2] * second[2]) * ratio,
    (scale[0] * scale[0] * second[0] + scale[2] * scale[2] * second[2]) * ratio,
    (scale[0] * scale[0] * second[0] + scale[1] * scale[1] * second[1]) * ratio,
  ]
  valid_mass({
    mass: value.mass * ratio,
    volume: value.volume * (scale[0] * scale[1] * scale[2]).abs(),
    com: Array::makei(3, k => value.com[k] * scale[k]),
    inertia: Array::makei(9, k => {
      if k / 3 == k % 3 {
        diag[k / 3]
      } else {
        i[k] * scale[k / 3] * scale[k % 3] * ratio
      }
    }),
  })
}

///|
/// Rigidly transform canonical mass properties. translation is the rigid
/// transform's translation, not the already transformed COM. Returned inertia
/// remains about returned COM. See transform_inertia for a Steiner shift.
pub fn transform_mass(
  value : MassProperties,
  rotation : Array[Double],
  offset : Array[Double],
) -> MassProperties raise {
  ignore(valid_mass(value))
  guard rotation.length() == 9 &&
    offset.length() == 3 &&
    rotation.all(finite) &&
    offset.all(finite) else {
    fail("invalid mass transform")
  }
  for i in 0..<3 {
    for j in 0..<3 {
      let dot = rotation[i] * rotation[j] +
        rotation[3 + i] * rotation[3 + j] +
        rotation[6 + i] * rotation[6 + j]
      guard (dot - (if i == j { 1.0 } else { 0.0 })).abs() <= 1.0e-10 else {
        fail("mass transform requires orthonormal rotation")
      }
    }
  }
  let determinant = rotation[0] *
    (rotation[4] * rotation[8] - rotation[5] * rotation[7]) -
    rotation[1] * (rotation[3] * rotation[8] - rotation[5] * rotation[6]) +
    rotation[2] * (rotation[3] * rotation[7] - rotation[4] * rotation[6])
  guard (determinant - 1).abs() <= 1.0e-10 else {
    fail("mass transform requires proper rotation")
  }
  let inertia = Array::make(9, 0.0)
  for i in 0..<3 {
    for j in 0..<3 {
      for a in 0..<3 {
        for b in 0..<3 {
          inertia[i * 3 + j] += rotation[i * 3 + a] *
            value.inertia[a * 3 + b] *
            rotation[j * 3 + b]
        }
      }
    }
  }
  let com = Array::makei(3, i => {
    offset[i] +
    rotation[i * 3] * value.com[0] +
    rotation[i * 3 + 1] * value.com[1] +
    rotation[i * 3 + 2] * value.com[2]
  })
  valid_mass({ ..value, com, inertia, })
}

///|
/// Pinned transform_inertia: rotate inertia about COM and shift it to a new
/// origin. offset is the ACTUAL COM expressed from that origin. Return value
/// is explicitly an origin tensor, not canonical MassProperties.
pub fn transform_inertia(
  mass : Double,
  inertia : Array[Double],
  offset : Array[Double],
  rotation : Array[Double],
) -> Array[Double] raise {
  let rotated = transform_mass(
    { mass, com: [0, 0, 0], inertia, volume: 0, },
    rotation,
    [0, 0, 0],
  )
  guard offset.length() == 3 && offset.all(finite) else {
    fail("finite actual COM offset required")
  }
  let radius = offset[0] * offset[0] +
    offset[1] * offset[1] +
    offset[2] * offset[2]
  let result = Array::makei(9, k => {
    rotated.inertia[k] +
    mass *
    (
      (if k / 3 == k % 3 { radius } else { 0.0 }) -
      offset[k / 3] * offset[k % 3]
    )
  })
  guard result.all(finite) else { fail("shifted inertia overflows") }
  result
}
