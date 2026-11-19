///|
/// Convert only a verified proper orthonormal matrix to MuJoCo wxyz.
/// Shared Vec3/Basis3 arithmetic lives in moonnum/geometry.
pub fn rotation_quaternion(
  rotation : @geometry.Basis3,
) -> Quaternion raise ConstantsError {
  guard values(rotation).all(finite) else {
    raise Invalid("rotation matrix contains nonfinite values")
  }
  let x = @geometry.vec3(rotation.xx, rotation.yx, rotation.zx)
  let y = @geometry.vec3(rotation.xy, rotation.yy, rotation.zy)
  let z = @geometry.vec3(rotation.xz, rotation.yz, rotation.zz)
  guard (x.dot(x) - 1.0).abs() <= 1.0e-10 &&
    (y.dot(y) - 1.0).abs() <= 1.0e-10 &&
    (z.dot(z) - 1.0).abs() <= 1.0e-10 &&
    x.dot(y).abs() <= 1.0e-10 &&
    x.dot(z).abs() <= 1.0e-10 &&
    y.dot(z).abs() <= 1.0e-10 &&
    (x.cross(y).dot(z) - 1.0).abs() <= 1.0e-10 else {
    raise Invalid("inertial/shape frame must be a proper orthonormal rotation")
  }
  let trace = rotation.xx + rotation.yy + rotation.zz
  let q : Quaternion = if trace > 0.0 {
    let s = 2.0 * (trace + 1.0).sqrt()
    {
      w: s / 4.0,
      x: (rotation.zy - rotation.yz) / s,
      y: (rotation.xz - rotation.zx) / s,
      z: (rotation.yx - rotation.xy) / s,
    }
  } else if rotation.xx >= rotation.yy && rotation.xx >= rotation.zz {
    let s = 2.0 * (1.0 + rotation.xx - rotation.yy - rotation.zz).sqrt()
    {
      w: (rotation.zy - rotation.yz) / s,
      x: s / 4.0,
      y: (rotation.xy + rotation.yx) / s,
      z: (rotation.xz + rotation.zx) / s,
    }
  } else if rotation.yy >= rotation.zz {
    let s = 2.0 * (1.0 + rotation.yy - rotation.xx - rotation.zz).sqrt()
    {
      w: (rotation.xz - rotation.zx) / s,
      x: (rotation.xy + rotation.yx) / s,
      y: s / 4.0,
      z: (rotation.yz + rotation.zy) / s,
    }
  } else {
    let s = 2.0 * (1.0 + rotation.zz - rotation.xx - rotation.yy).sqrt()
    {
      w: (rotation.yx - rotation.xy) / s,
      x: (rotation.xz + rotation.zx) / s,
      y: (rotation.yz + rotation.zy) / s,
      z: s / 4.0,
    }
  }
  let norm = (q.w * q.w + q.x * q.x + q.y * q.y + q.z * q.z).sqrt()
  guard finite(norm) && norm > 0.0 else {
    raise Invalid("rotation quaternion normalization failed")
  }
  let divisor = if q.w < 0.0 { -norm } else { norm }
  { w: q.w / divisor, x: q.x / divisor, y: q.y / divisor, z: q.z / divisor, }
}

///|
/// Physics-domain symmetric 3x3 Jacobi decomposition. moonnum currently has
/// no symmetric eigensolver. This CPU/Double implementation preserves Newton's
/// descending principal moments/proper frame/wxyz convention, not Warp's exact
/// float32 eig3 iteration order or degenerate-eigenvector/sign choices.
pub fn principal_inertia(
  tensor : @geometry.Basis3,
) -> PrincipalInertia raise ConstantsError {
  let flat = values(tensor)
  guard flat.all(finite) else {
    raise Invalid("body inertia tensor contains nonfinite values")
  }
  let mut scale = 0.0
  for value in flat {
    scale = @math.maximum(scale, value.abs())
  }
  if scale == 0.0 {
    return {
      moments: @geometry.vec3(0.0, 0.0, 0.0),
      orientation: { w: 1.0, x: 0.0, y: 0.0, z: 0.0, },
      axes: @geometry.identity_basis3(),
    }
  }
  let original = [
    flat[0:3].to_owned(),
    flat[3:6].to_owned(),
    flat[6:9].to_owned(),
  ].map(row => row.map(value => value / scale))
  for i in 0..<3 {
    for j in (i + 1)..<3 {
      guard (original[i][j] - original[j][i]).abs() <= 1.0e-12 else {
        raise Invalid("body inertia tensor is not symmetric")
      }
    }
  }
  let a = matrix_copy(original)
  for i in 0..<3 {
    for j in (i + 1)..<3 {
      let average = (a[i][j] + a[j][i]) / 2.0
      a[i][j] = average
      a[j][i] = average
    }
  }
  let vectors = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
  let mut converged = false
  for _iteration in 0..<64 {
    let mut p = 0
    let mut q = 1
    for i in 0..<3 {
      for j in (i + 1)..<3 {
        if a[i][j].abs() > a[p][q].abs() {
          p = i
          q = j
        }
      }
    }
    if a[p][q].abs() <= 1.0e-14 {
      converged = true
      break
    }
    let angle = @math.atan2(2.0 * a[p][q], a[q][q] - a[p][p]) / 2.0
    let c = @math.cos(angle)
    let s = @math.sin(angle)
    let app = a[p][p]
    let aqq = a[q][q]
    let apq = a[p][q]
    for k in 0..<3 {
      if k != p && k != q {
        let akp = a[k][p]
        let akq = a[k][q]
        a[k][p] = c * akp - s * akq
        a[p][k] = a[k][p]
        a[k][q] = s * akp + c * akq
        a[q][k] = a[k][q]
      }
      let vp = vectors[k][p]
      let vq = vectors[k][q]
      vectors[k][p] = c * vp - s * vq
      vectors[k][q] = s * vp + c * vq
    }
    a[p][p] = c * c * app - 2.0 * c * s * apq + s * s * aqq
    a[q][q] = s * s * app + 2.0 * c * s * apq + c * c * aqq
    a[p][q] = 0.0
    a[q][p] = 0.0
  }
  guard converged else {
    raise Invalid("principal inertia Jacobi iteration did not converge")
  }
  let moments = [a[0][0], a[1][1], a[2][2]]
  for i in 0..<2 {
    for j in 0..<(2 - i) {
      if moments[j] < moments[j + 1] {
        let temp = moments[j]
        moments[j] = moments[j + 1]
        moments[j + 1] = temp
        for row in vectors {
          let temp = row[j]
          row[j] = row[j + 1]
          row[j + 1] = temp
        }
      }
    }
  }
  guard moments.all(value => value >= -1.0e-12) else {
    raise Invalid("body inertia tensor is not positive semidefinite")
  }
  for i in 0..<3 {
    if moments[i] < 0.0 {
      moments[i] = 0.0
    }
  }
  let x = @geometry.vec3(vectors[0][0], vectors[1][0], vectors[2][0])
  let y = @geometry.vec3(vectors[0][1], vectors[1][1], vectors[2][1])
  let z = @geometry.vec3(vectors[0][2], vectors[1][2], vectors[2][2])
  if x.cross(y).dot(z) < 0.0 {
    for row in vectors {
      row[2] = -row[2]
    }
  }
  for i in 0..<3 {
    for j in 0..<3 {
      let mut reconstructed = 0.0
      for k in 0..<3 {
        reconstructed += vectors[i][k] * moments[k] * vectors[j][k]
      }
      guard finite(reconstructed) &&
        (reconstructed - original[i][j]).abs() <= 1.0e-10 else {
        raise Invalid(
          "principal inertia reconstruction residual exceeds CPU/Double contract",
        )
      }
    }
  }
  let axes = basis(vectors)
  let scaled = moments.map(value => value * scale)
  guard scaled.all(finite) else {
    raise Invalid("principal inertia moments overflow")
  }
  {
    moments: @geometry.vec3(scaled[0], scaled[1], scaled[2]),
    orientation: rotation_quaternion(axes),
    axes,
  }
}

///|
/// Pure host equivalent of mapped mass/ipos/optional gravcomp plus inertia
/// updates. All outputs are new arrays; sentinel rows retain their old values.
pub fn update_bodies(
  request : BodyUpdate,
) -> Array[Array[BodyConstant]] raise ConstantsError {
  let source = request.newton
  let n = source.mass.length()
  guard source.com.length() == n &&
    source.inertia.length() == n &&
    source.mass.all(value => finite(value) && value >= 0.0) else {
    raise Invalid("Newton body mass/COM/inertia cardinality is inconsistent")
  }
  if source.gravcomp is Some(values) {
    guard values.length() == n && values.all(finite) else {
      raise Invalid(
        "Newton gravity compensation cardinality/values are invalid",
      )
    }
  }
  for value in source.com {
    check_vector(value, "body COM")
  }
  let decomposed = source.inertia.map(principal_inertia)
  guard !request.mapping.is_empty() &&
    request.mapping.length() == request.existing.length() else {
    raise Invalid("body mapping world cardinality is invalid")
  }
  let width = request.mapping[0].length()
  guard width > 0 &&
    request.mapping.all(row => row.length() == width) &&
    request.existing.all(row => row.length() == width) else {
    raise Invalid(
      "body mapping/output rows must have equal positive cardinality",
    )
  }
  request.mapping.mapi(fn(world, row) {
    row.mapi(fn(body, index) {
      let previous = request.existing[world][body]
      guard finite(previous.mass) &&
        previous.mass >= 0.0 &&
        vector_finite(previous.ipos) &&
        vector_finite(previous.inertia) &&
        quaternion_finite(previous.iquat) &&
        finite(previous.gravcomp) else {
        raise Invalid("existing body constants contain invalid values")
      }
      guard index >= -1 && index < n else {
        raise Invalid("body mapping index outside Newton source")
      }
      if index == -1 {
        previous
      } else {
        {
          mass: source.mass[index],
          ipos: source.com[index],
          inertia: decomposed[index].moments,
          iquat: decomposed[index].orientation,
          gravcomp: match source.gravcomp {
            Some(values) => values[index]
            None => previous.gravcomp
          },
        }
      }
    })
  })
}
