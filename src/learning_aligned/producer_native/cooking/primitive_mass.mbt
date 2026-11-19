///|
fn diagonal(
  mass : Double,
  x : Double,
  y : Double,
  z : Double,
  com_z : Double,
  volume : Double,
) -> MassProperties {
  { mass, com: [0, 0, com_z], inertia: [x, 0, 0, 0, y, 0, 0, 0, z], volume, }
}

///|
fn solid_primitive(
  kind : String,
  s : Array[Double],
  density : Double,
) -> MassProperties raise {
  let x = s[0]
  let y = s[1]
  let z = s[2]
  let pi = @math.pi
  match kind {
    "plane" | "heightfield" | "gaussian" => diagonal(0, 0, 0, 0, 0, 0)
    "sphere" => {
      let v = 4.0 / 3 * pi * x * x * x
      let m = density * v
      let i = 0.4 * m * x * x
      diagonal(m, i, i, i, 0, v)
    }
    "box" => {
      let v = 8.0 * x * y * z
      let m = density * v
      diagonal(
        m,
        m * (y * y + z * z) / 3,
        m * (x * x + z * z) / 3,
        m * (x * x + y * y) / 3,
        0,
        v,
      )
    }
    "ellipsoid" => {
      let v = 4.0 / 3 * pi * x * y * z
      let m = density * v
      diagonal(
        m,
        m * (y * y + z * z) / 5,
        m * (x * x + z * z) / 5,
        m * (x * x + y * y) / 5,
        0,
        v,
      )
    }
    "capsule" => {
      let h = 2.0 * y
      let vs = 4.0 / 3 * pi * x * x * x
      let vc = pi * x * x * h
      let ms = density * vs
      let mc = density * vc
      let ia = mc * (0.25 * x * x + h * h / 12) +
        ms * (0.4 * x * x + 0.375 * x * h + 0.25 * h * h)
      diagonal(ms + mc, ia, ia, (mc * 0.5 + ms * 0.4) * x * x, 0, vs + vc)
    }
    "cone" => {
      let h = 2.0 * y
      let v = pi * x * x * h / 3
      let m = density * v
      let ia = 0.15 * m * x * x + 0.0375 * m * h * h
      diagonal(m, ia, ia, 0.3 * m * x * x, -h / 4, v)
    }
    "cylinder" =>
      if z == 0 {
        let h = 2.0 * y
        let v = pi * x * x * h
        let m = density * v
        let ia = m * (3.0 * x * x + h * h) / 12
        diagonal(m, ia, ia, 0.5 * m * x * x, 0, v)
      } else {
        guard z >= y else {
          fail("barrel radius must be zero or at least half height")
        }
        // Newton uses leggauss(32). Resolve the same 32-point rule by the
        // standard Legendre/Newton construction, without generated tables.
        let mut vol = 0.0
        let mut radial = 0.0
        let mut axial = 0.0
        for i in 0..<16 {
          let mut root = @math.cos(pi * (i.to_double() + 0.75) / 32.5)
          let mut derivative = 0.0
          for _ in 0..<32 {
            let mut p0 = 1.0
            let mut p1 = root
            for n in 2..<=32 {
              let pn = (
                  (2 * n - 1).to_double() * root * p1 - (n - 1).to_double() * p0
                ) /
                n.to_double()
              p0 = p1
              p1 = pn
            }
            derivative = 32.0 * (root * p1 - p0) / (root * root - 1)
            let step = p1 / derivative
            root -= step
            if step.abs() < 1.0e-15 {
              break
            }
          }
          let weight = 2.0 / ((1.0 - root * root) * derivative * derivative) * y
          let zz = y * root
          let end = (z * z - y * y).sqrt()
          let profile = x + (y * y - zz * zz) / ((z * z - zz * zz).sqrt() + end)
          let r2 = profile * profile
          vol += 2.0 * pi * weight * r2
          axial += pi * weight * r2 * r2
          radial += 2.0 * pi * weight * (0.25 * r2 * r2 + r2 * zz * zz)
        }
        diagonal(
          density * vol,
          density * radial,
          density * radial,
          density * axial,
          0,
          vol,
        )
      }
    _ => fail("unsupported primitive inertia type")
  }
}

///|
/// Complete pinned analytic primitive mass branches, including barrel
/// quadrature and finite-thickness shells. scale is Newton's native encoding.
pub fn primitive_mass(
  kind : String,
  scale : Array[Double],
  density : Double,
  is_solid : Bool,
  thickness : Double,
) -> MassProperties raise {
  guard scale.length() == 3 &&
    scale.all(x => finite(x) && x >= 0) &&
    finite(density) &&
    density >= 0 &&
    finite(thickness) &&
    thickness >= 0 else {
    fail("invalid primitive mass dimensions/density/thickness")
  }
  let outer = solid_primitive(kind, scale, density)
  if is_solid ||
    density == 0 ||
    kind == "plane" ||
    kind == "heightfield" ||
    kind == "gaussian" {
    return valid_mass(outer)
  }
  if thickness == 0 {
    return diagonal(0, 0, 0, 0, outer.com[2], 0)
  }
  let dims = if kind == "sphere" {
    [scale[0]]
  } else if kind == "box" || kind == "ellipsoid" {
    scale.copy()
  } else {
    [scale[0], scale[1]]
  }
  guard dims.all(d => thickness < d) else {
    fail("shell thickness must be smaller than every radius/halfextent")
  }
  let inner_scale = scale.copy()
  inner_scale[0] -= thickness
  if kind != "sphere" {
    inner_scale[1] -= thickness
  }
  if kind == "box" ||
    kind == "ellipsoid" ||
    (kind == "cylinder" && scale[2] > 0) {
    inner_scale[2] -= thickness
  }
  let inner = solid_primitive(kind, inner_scale, density)
  let m = outer.mass - inner.mass
  let v = outer.volume - inner.volume
  guard m > 0 else { fail("shell mass underflows to zero") }
  let com = Array::makei(3, i => {
    (outer.mass * outer.com[i] - inner.mass * inner.com[i]) / m
  })
  let tensor = Array::makei(9, i => outer.inertia[i] - inner.inertia[i])
  if kind == "cone" {
    for (item, sign) in [(outer, 1.0), (inner, -1.0)] {
      let d = item.com[2] - com[2]
      tensor[0] += sign * item.mass * d * d
      tensor[4] += sign * item.mass * d * d
    }
  }
  valid_mass({ mass: m, com, inertia: tensor, volume: v, })
}
