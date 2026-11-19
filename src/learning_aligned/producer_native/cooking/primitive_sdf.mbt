///|
/// Pinned Z-up analytic primitive distance formulas, including the source's
/// approximate ellipsoid and exact circular-profile barrel-cylinder branch.
pub fn primitive_distance(
  kind : String,
  scale : Array[Double],
  position : Array[Double],
) -> Double raise {
  guard scale.length() == 3 &&
    scale.all(x => finite(x) && x >= 0) &&
    position.length() == 3 &&
    position.all(finite) else {
    fail("invalid primitive SDF scale/query")
  }
  let x = position[0]
  let y = position[1]
  let z = position[2]
  let radius = scale[0]
  let h = scale[1]
  let radial = (x * x + y * y).sqrt()
  let result = match kind {
    "sphere" => (x * x + y * y + z * z).sqrt() - radius
    "box" => {
      let a = x.abs() - scale[0]
      let b = y.abs() - scale[1]
      let c = z.abs() - scale[2]
      let px = maxd(a, 0)
      let py = maxd(b, 0)
      let pz = maxd(c, 0)
      (px * px + py * py + pz * pz).sqrt() - maxd(-maxd(a, maxd(b, c)), 0)
    }
    "capsule" => {
      let dz = maxd(z.abs() - h, 0)
      (x * x + y * y + dz * dz).sqrt() - radius
    }
    "cylinder" => {
      let barrel = scale[2]
      if barrel == 0 {
        let a = radial - radius
        let b = z.abs() - h
        let pa = maxd(a, 0)
        let pb = maxd(b, 0)
        (pa * pa + pb * pb).sqrt() - maxd(-maxd(a, b), 0)
      } else {
        guard barrel >= h else {
          fail("barrel SDF radius must be >=halfheight")
        }
        let end = (barrel * barrel - h * h).sqrt()
        let center = radius - end
        let zz = z.abs()
        let dr = radial - center
        let length = (dr * dr + zz * zz).sqrt()
        let mut ar = center + barrel
        let mut az = 0.0
        if length > 1.0e-8 {
          ar = center + barrel * dr / length
          az = barrel * zz / length
        }
        if ar - center < end {
          ar = radius
          az = h
        }
        let arc = ((radial - ar) * (radial - ar) + (zz - az) * (zz - az)).sqrt()
        let cap = (maxd(radial - radius, 0) * maxd(radial - radius, 0) +
        (zz - h) * (zz - h)).sqrt()
        let distance = -maxd(-arc, -cap)
        let inside = zz <= h &&
          radial <= center + maxd(barrel * barrel - zz * zz, 0).sqrt()
        if inside {
          -distance
        } else {
          distance
        }
      }
    }
    "ellipsoid" => {
      let radii = scale.map(r => maxd(r.abs(), 1.0e-8))
      let mut a = 0.0
      let mut b = 0.0
      for k in 0..<3 {
        let q = position[k] / radii[k]
        let p = q / radii[k]
        a += q * q
        b += p * p
      }
      let k0 = a.sqrt()
      let k1 = b.sqrt()
      if k1 > 1.0e-8 {
        k0 * (k0 - 1) / k1
      } else {
        -(-maxd(-radii[0], maxd(-radii[1], -radii[2])))
      }
    }
    "cone" => {
      let ca_x = if z < 0 { maxd(radial - radius, 0) } else { radial }
      let ca_y = z.abs() - h
      let kx = -radius
      let ky = 2.0 * h
      let denominator = kx * kx + ky * ky
      let t = if denominator > 0 {
        maxd(0, -maxd(-1, -((-radial * kx + (h - z) * ky) / denominator)))
      } else {
        0.0
      }
      let cb_x = radial + kx * t
      let cb_y = z - h + ky * t
      let distance = (-maxd(
        -(ca_x * ca_x + ca_y * ca_y),
        -(cb_x * cb_x + cb_y * cb_y),
      )).sqrt()
      if cb_x < 0 && ca_y < 0 {
        -distance
      } else {
        distance
      }
    }
    _ => fail("unsupported primitive SDF type")
  }
  guard finite(result) else { fail("primitive SDF overflow") }
  result
}

///|
fn primitive_extents(
  kind : String,
  scale : Array[Double],
) -> Array[Double] raise {
  ignore(primitive_distance(kind, scale, [0, 0, 0]))
  match kind {
    "sphere" => [scale[0], scale[0], scale[0]]
    "capsule" => [scale[0], scale[0], scale[0] + scale[1]]
    "cone" => [scale[0], scale[0], scale[1]]
    "cylinder" => {
      let radius = scale[0] +
        (if scale[2] > 0 {
          scale[2] - (scale[2] * scale[2] - scale[1] * scale[1]).sqrt()
        } else {
          0.0
        })
      [radius, radius, scale[1]]
    }
    _ => scale.copy()
  }
}

///|
pub fn primitive_sparse_sdf(
  kind : String,
  scale : Array[Double],
  options : SdfOptions,
) -> SparseSdf raise {
  let ext = primitive_extents(kind, scale)
  let lower = ext.map(x => -x - options.margin)
  let upper = ext.map(x => x + options.margin)
  build_sparse_sdf(
    lower,
    upper,
    { ..options, sign_method: "analytic-" + kind, },
    points => {
      let out = []
      for i in 0..<(points.length() / 3) {
        out.push(
          Float::from_double(
            primitive_distance(kind, scale, [
              points[i * 3],
              points[i * 3 + 1],
              points[i * 3 + 2],
            ]),
          ).to_double(),
        )
      }
      out
    },
  )
}
