///|
/// Authored complete inertial data only. Missing/inferred USD properties remain
/// absent; no guessed mass, COM, identity inertia or mesh integration is used.
fn mass_properties(value : Json) -> MassProperties? raise {
  guard value
    is {
      "mass": Number(mass),
      "center_of_mass": Array(com),
      "diagonal_inertia": Array(diagonal),
      "principal_axes_wxyz": Array(q),
      ..
    } else {
    return None
  }
  guard com.all(x => x is Number(_)) &&
    diagonal.all(x => x is Number(_)) &&
    q.all(x => x is Number(_)) else {
    return None
  }
  let com : Array[Double] = @json.from_json(Json(com))
  let diagonal : Array[Double] = @json.from_json(Json(diagonal))
  let q : Array[Double] = @json.from_json(Json(q))
  finite([mass])
  finite(com)
  finite(diagonal)
  guard mass > 0.0 &&
    com.length() == 3 &&
    diagonal.length() == 3 &&
    diagonal.all(x => x > 0.0) else {
    fail("invalid explicitly authored positive mass/inertia")
  }
  let (ix, iy, iz) = (diagonal[0], diagonal[1], diagonal[2])
  guard ix <= iy + iz + 1.0e-9 &&
    iy <= ix + iz + 1.0e-9 &&
    iz <= ix + iy + 1.0e-9 else {
    fail("principal inertia violates physical triangle inequalities")
  }
  let b = frame([0.0, 0.0, 0.0], q).basis
  fn tensor(dx : Double, dy : Double, dz : Double) -> Array[Double] {
    let d : @geo.Basis3 = {
      xx: dx,
      xy: 0.0,
      xz: 0.0,
      yx: 0.0,
      yy: dy,
      yz: 0.0,
      zx: 0.0,
      zy: 0.0,
      zz: dz,
    }
    let t = b.mul_basis3(d).mul_basis3(transpose(b))
    [t.xx, t.xy, t.xz, t.yx, t.yy, t.yz, t.zx, t.zy, t.zz]
  }
  let inverse_mass = 1.0 / mass
  let inertia = tensor(ix, iy, iz)
  let inverse_inertia = tensor(1.0 / ix, 1.0 / iy, 1.0 / iz)
  finite([inverse_mass])
  finite(inertia)
  finite(inverse_inertia)
  Some({ mass, inverse_mass, center_of_mass: com, inertia, inverse_inertia, })
}
