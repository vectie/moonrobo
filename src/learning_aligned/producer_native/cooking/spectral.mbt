///|
// Small symmetric 3x3 Jacobi eigensystem, shared by hull rank and inertia
// correction. Columns of vectors correspond to ascending eigenvalues.
fn eigen3(input : Array[Double]) -> (Array[Double], Array[Double]) raise {
  guard input.length() == 9 && input.all(finite) else {
    fail("finite 3x3 symmetric matrix required")
  }
  let mut scale = 0.0
  for x in input {
    scale = maxd(scale, x.abs())
  }
  if scale == 0 {
    scale = 1
  }
  let a = input.map(x => x / scale)
  let vectors = [1.0, 0, 0, 0, 1, 0, 0, 0, 1]
  for i in 0..<3 {
    for j in 0..<3 {
      guard (a[i * 3 + j] - a[j * 3 + i]).abs() <=
        1.0e-10 * maxd(1, a[i * 3 + j].abs()) else {
        fail("eigensystem matrix is not symmetric")
      }
    }
  }
  for _ in 0..<64 {
    let mut p = 0
    let mut q = 1
    for (i, j) in [(0, 2), (1, 2)] {
      if a[i * 3 + j].abs() > a[p * 3 + q].abs() {
        p = i
        q = j
      }
    }
    let off = a[p * 3 + q]
    if off.abs() <=
      1.0e-15 * maxd(1.0e-300, maxd(a[0].abs(), maxd(a[4].abs(), a[8].abs()))) {
      break
    }
    let tau = (a[q * 3 + q] - a[p * 3 + p]) / (2 * off)
    let t = (if tau >= 0 { 1.0 } else { -1.0 }) /
      (tau.abs() + (1.0 + tau * tau).sqrt())
    let c = 1.0 / (1.0 + t * t).sqrt()
    let s = t * c
    let app = a[p * 3 + p]
    let aqq = a[q * 3 + q]
    a[p * 3 + p] = app - t * off
    a[q * 3 + q] = aqq + t * off
    a[p * 3 + q] = 0
    a[q * 3 + p] = 0
    for k in 0..<3 {
      if k != p && k != q {
        let x = a[k * 3 + p]
        let y = a[k * 3 + q]
        a[k * 3 + p] = c * x - s * y
        a[p * 3 + k] = a[k * 3 + p]
        a[k * 3 + q] = s * x + c * y
        a[q * 3 + k] = a[k * 3 + q]
      }
      let x = vectors[k * 3 + p]
      let y = vectors[k * 3 + q]
      vectors[k * 3 + p] = c * x - s * y
      vectors[k * 3 + q] = s * x + c * y
    }
  }
  guard a.all(finite) &&
    maxd(a[1].abs(), maxd(a[2].abs(), a[5].abs())) <=
    1.0e-13 * maxd(1.0e-300, maxd(a[0].abs(), maxd(a[4].abs(), a[8].abs()))) else {
    fail("3x3 Jacobi eigensystem failed to converge")
  }
  let order = [0, 1, 2]
  order.sort_by((i, j) => a[i * 3 + i].compare(a[j * 3 + j]))
  let values = order.map(i => a[i * 3 + i] * scale)
  let result = Array::makei(9, k => vectors[k / 3 * 3 + order[k % 3]])
  guard values.all(finite) && result.all(finite) else {
    fail("3x3 eigensystem overflow")
  }
  (values, result)
}

///|
fn maxd(a : Double, b : Double) -> Double {
  if a > b {
    a
  } else {
    b
  }
}

///|
pub(all) struct InertiaCorrection {
  mass : Double
  inertia : Array[Double]
  corrected : Bool
} derive(ToJson)

///|
/// Pinned verify_and_correct_inertia ordering/tolerances, using CPU/Double
/// Jacobi instead of NumPy eigvalsh. Warnings become an explicit changed flag.
pub fn correct_inertia(
  mass : Double,
  input : Array[Double],
  balance : Bool,
  bound_mass : Double?,
  bound_inertia : Double?,
) -> InertiaCorrection raise {
  guard input.length() == 9 &&
    bound_mass.map(x => finite(x) && x >= 0).unwrap_or(true) &&
    bound_inertia.map(x => finite(x) && x >= 0).unwrap_or(true) else {
    fail("invalid inertia correction shape/bounds")
  }
  if !finite(mass) || !input.all(finite) {
    return { mass: 0, inertia: Array::make(9, 0.0), corrected: true, }
  }
  let mut m = mass
  let mut changed = false
  if m < 0 {
    m = 0
    changed = true
  } else if bound_mass is Some(bound) && m > 0 && m < bound {
    m = bound
    changed = true
  }
  if m == 0 {
    return {
      mass: 0,
      inertia: Array::make(9, 0.0),
      corrected: changed || input.any(x => x != 0),
    }
  }
  let a = Array::makei(9, k => (input[k] + input[k % 3 * 3 + k / 3]) / 2)
  for k in 0..<9 {
    if (input[k] - a[k]).abs() > 1.0e-8 + 1.0e-5 * a[k].abs() {
      changed = true
    }
  }
  let (eig, _) = eigen3(a)
  let threshold = maxd(1.0e-6 * eig[2], 1.0e-10)
  fn shift(value : Double) -> Unit {
    for i in 0..<3 {
      a[i * 3 + i] += value
      eig[i] += value
    }
  }
  if eig[0] < threshold {
    shift(threshold - eig[0] + 1.0e-6)
    changed = true
  }
  if bound_inertia is Some(bound) && eig[0] < bound {
    shift(bound - eig[0])
    changed = true
  }
  if eig[0] + eig[1] < eig[2] - maxd(1.1920928955078125e-7 * eig[2], 1.0e-10) &&
    balance {
    shift(eig[2] - eig[0] - eig[1] + 1.0e-6)
    changed = true
  }
  if eig.any(x => x <= 0 || !finite(x)) {
    shift(eig[0].abs() + 1.0e-6)
    changed = true
  }
  guard a.all(finite) else { fail("corrected inertia overflows") }
  { mass: m, inertia: a, corrected: changed, }
}
