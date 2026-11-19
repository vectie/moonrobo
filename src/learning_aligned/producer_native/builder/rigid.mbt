///|
fn finite(values : Array[Double]) -> Unit raise {
  guard values.all(v => !v.is_nan() && !v.is_inf()) else {
    fail("nonfinite rigid body data")
  }
}

///|
fn transpose(b : @geo.Basis3) -> @geo.Basis3 {
  {
    xx: b.xx,
    xy: b.yx,
    xz: b.zx,
    yx: b.xy,
    yy: b.yy,
    yz: b.zy,
    zx: b.xz,
    zy: b.yz,
    zz: b.zz,
  }
}

///|
fn checked_transform(t : @geo.Transform3) -> @geo.Transform3 raise {
  let b = t.basis
  finite([
    b.xx,
    b.xy,
    b.xz,
    b.yx,
    b.yy,
    b.yz,
    b.zx,
    b.zy,
    b.zz,
    t.translation.x,
    t.translation.y,
    t.translation.z,
  ])
  let x = @geo.vec3(b.xx, b.yx, b.zx)
  let y = @geo.vec3(b.xy, b.yy, b.zy)
  let z = @geo.vec3(b.xz, b.yz, b.zz)
  guard (x.length_squared() - 1.0).abs() <= 1.0e-6 &&
    (y.length_squared() - 1.0).abs() <= 1.0e-6 &&
    (z.length_squared() - 1.0).abs() <= 1.0e-6 &&
    x.dot(y).abs() <= 1.0e-6 &&
    x.dot(z).abs() <= 1.0e-6 &&
    y.dot(z).abs() <= 1.0e-6 &&
    (x.cross(y).dot(z) - 1.0).abs() <= 1.0e-6 else {
    fail(
      "builder subset requires a proper rigid transform without scale, shear or reflection",
    )
  }
  t
}

///|
fn frame(position : Array[Double], q : Array[Double]) -> @geo.Transform3 raise {
  guard position.length() == 3 && q.length() == 4 else {
    fail("invalid pose width")
  }
  finite(position)
  finite(q)
  let (w, x, y, z) = (q[0], q[1], q[2], q[3])
  guard (w * w + x * x + y * y + z * z - 1.0).abs() <= 1.0e-6 else {
    fail("nonunit quaternion")
  }
  checked_transform(
    @geo.transform3(
      {
        xx: 1.0 - 2.0 * (y * y + z * z),
        xy: 2.0 * (x * y - z * w),
        xz: 2.0 * (x * z + y * w),
        yx: 2.0 * (x * y + z * w),
        yy: 1.0 - 2.0 * (x * x + z * z),
        yz: 2.0 * (y * z - x * w),
        zx: 2.0 * (x * z - y * w),
        zy: 2.0 * (y * z + x * w),
        zz: 1.0 - 2.0 * (x * x + y * y),
      },
      @geo.vec3(position[0], position[1], position[2]),
    ),
  )
}

///|
fn inverse(t : @geo.Transform3) -> @geo.Transform3 {
  let b = transpose(t.basis)
  @geo.transform3(b, b.mul_vec3(t.translation).scale(-1.0))
}

///|
fn usd_transform(m : Array[Double]) -> @geo.Transform3 raise {
  guard m.length() == 16 else { fail("USD matrix must have sixteen entries") }
  finite(m)
  guard m[3].abs() < 1.0e-9 &&
    m[7].abs() < 1.0e-9 &&
    m[11].abs() < 1.0e-9 &&
    (m[15] - 1.0).abs() < 1.0e-9 else {
    fail("nonaffine USD matrix")
  }
  checked_transform(
    @geo.transform3(
      {
        xx: m[0],
        xy: m[4],
        xz: m[8],
        yx: m[1],
        yy: m[5],
        yz: m[9],
        zx: m[2],
        zy: m[6],
        zz: m[10],
      },
      @geo.vec3(m[12], m[13], m[14]),
    ),
  )
}

///|
fn pose(t : @geo.Transform3) -> Array[Double] {
  let b = t.basis
  let (w, x, y, z) = if b.xx + b.yy + b.zz > 0.0 {
    let s = (1.0 + b.xx + b.yy + b.zz).sqrt() * 2.0
    (0.25 * s, (b.zy - b.yz) / s, (b.xz - b.zx) / s, (b.yx - b.xy) / s)
  } else if b.xx > b.yy && b.xx > b.zz {
    let s = (1.0 + b.xx - b.yy - b.zz).sqrt() * 2.0
    ((b.zy - b.yz) / s, 0.25 * s, (b.xy + b.yx) / s, (b.xz + b.zx) / s)
  } else if b.yy > b.zz {
    let s = (1.0 + b.yy - b.xx - b.zz).sqrt() * 2.0
    ((b.xz - b.zx) / s, (b.xy + b.yx) / s, 0.25 * s, (b.yz + b.zy) / s)
  } else {
    let s = (1.0 + b.zz - b.xx - b.yy).sqrt() * 2.0
    ((b.yx - b.xy) / s, (b.xz + b.zx) / s, (b.yz + b.zy) / s, 0.25 * s)
  }
  [t.translation.x, t.translation.y, t.translation.z, x, y, z, w]
}

///|
fn axis(name : String) -> @geo.Vec3 raise {
  match name {
    "X" => @geo.vec3(1, 0, 0)
    "Y" => @geo.vec3(0, 1, 0)
    "Z" => @geo.vec3(0, 0, 1)
    _ => fail("unsupported joint axis")
  }
}
