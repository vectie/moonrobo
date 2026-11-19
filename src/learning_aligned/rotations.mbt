// Parallel port of aligned/rotations.py. Matrices are row-major; quaternions wxyz.

///|
pub fn vec_add(a : Array[Double], b : Array[Double]) -> Array[Double] {
  Array::makei(a.length(), i => a[i] + b[i])
}

///|
pub fn vec_sub(a : Array[Double], b : Array[Double]) -> Array[Double] {
  Array::makei(a.length(), i => a[i] - b[i])
}

///|
pub fn vec_scale(a : Array[Double], s : Double) -> Array[Double] {
  a.map(x => x * s)
}

///|
pub fn cross(a : Array[Double], b : Array[Double]) -> Array[Double] {
  [
    a[1] * b[2] - a[2] * b[1],
    a[2] * b[0] - a[0] * b[2],
    a[0] * b[1] - a[1] * b[0],
  ]
}

///|
pub fn mat_mul(a : Array[Double], b : Array[Double]) -> Array[Double] {
  Array::makei(9, i => {
    let r = i / 3
    let c = i % 3
    a[r * 3] * b[c] + a[r * 3 + 1] * b[3 + c] + a[r * 3 + 2] * b[6 + c]
  })
}

///|
pub fn mat_vec(a : Array[Double], v : Array[Double]) -> Array[Double] {
  Array::makei(3, r => {
    a[r * 3] * v[0] + a[r * 3 + 1] * v[1] + a[r * 3 + 2] * v[2]
  })
}

///|
pub fn transpose(a : Array[Double]) -> Array[Double] {
  Array::makei(9, i => a[i % 3 * 3 + i / 3])
}

///|
pub fn identity() -> Array[Double] {
  [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]
}

///|
fn normalize(q : Array[Double]) -> Array[Double] {
  let n = q.fold(init=0.0, (s, x) => s + x * x).sqrt().max(1.0e-12)
  q.map(x => x / n)
}

///|
pub fn quat_to_mat(input : Array[Double]) -> Array[Double] {
  let q = normalize(input)
  let (w, x, y, z) = (q[0], q[1], q[2], q[3])
  [
    1.0 - 2.0 * (y * y + z * z),
    2.0 * (x * y - w * z),
    2.0 * (x * z + w * y),
    2.0 * (x * y + w * z),
    1.0 - 2.0 * (x * x + z * z),
    2.0 * (y * z - w * x),
    2.0 * (x * z - w * y),
    2.0 * (y * z + w * x),
    1.0 - 2.0 * (x * x + y * y),
  ]
}

///|
pub fn mat_to_quat(m : Array[Double]) -> Array[Double] {
  let candidates = [
    (1.0 + m[0] + m[4] + m[8]).max(1.0e-10).sqrt() / 2.0,
    (1.0 + m[0] - m[4] - m[8]).max(1.0e-10).sqrt() / 2.0,
    (1.0 - m[0] + m[4] - m[8]).max(1.0e-10).sqrt() / 2.0,
    (1.0 - m[0] - m[4] + m[8]).max(1.0e-10).sqrt() / 2.0,
  ]
  let mut best = 0
  for i in 1..<4 {
    if candidates[i] > candidates[best] {
      best = i
    }
  }
  let d = 4.0 * candidates[best]
  let q = normalize(
    match best {
      0 =>
        [candidates[0], (m[7] - m[5]) / d, (m[2] - m[6]) / d, (m[3] - m[1]) / d]
      1 =>
        [(m[7] - m[5]) / d, candidates[1], (m[1] + m[3]) / d, (m[2] + m[6]) / d]
      2 =>
        [(m[2] - m[6]) / d, (m[1] + m[3]) / d, candidates[2], (m[5] + m[7]) / d]
      _ =>
        [(m[3] - m[1]) / d, (m[2] + m[6]) / d, (m[5] + m[7]) / d, candidates[3]]
    },
  )
  if q[0] < 0.0 {
    vec_scale(q, -1.0)
  } else {
    q
  }
}

///|
pub fn axis_angle_to_mat(axis : Array[Double], angle : Double) -> Array[Double] {
  let (x, y, z) = (axis[0], axis[1], axis[2])
  let (c, s) = (angle.cos(), angle.sin())
  let k = 1.0 - c
  [
    c + x * x * k,
    x * y * k - z * s,
    x * z * k + y * s,
    y * x * k + z * s,
    c + y * y * k,
    y * z * k - x * s,
    z * x * k - y * s,
    z * y * k + x * s,
    c + z * z * k,
  ]
}

///|
pub fn skew(v : Array[Double]) -> Array[Double] {
  [0.0, -v[2], v[1], v[2], 0.0, -v[0], -v[1], v[0], 0.0]
}

///|
pub fn so3_exp(v : Array[Double]) -> Array[Double] {
  let theta2 = v.fold(init=0.0, (s, x) => s + x * x)
  let theta = (theta2 + 1.0e-12).sqrt()
  let a = if theta2 < 1.0e-8 { 1.0 - theta2 / 6.0 } else { theta.sin() / theta }
  let b = if theta2 < 1.0e-8 {
    0.5 - theta2 / 24.0
  } else {
    (1.0 - theta.cos()) / (theta2 + 1.0e-12)
  }
  let k = skew(v)
  let k2 = mat_mul(k, k)
  let eye = identity()
  Array::makei(9, i => eye[i] + a * k[i] + b * k2[i])
}

///|
pub fn quat_to_rotvec(input : Array[Double]) -> Array[Double] {
  let q = if input[0] < 0.0 { vec_scale(input, -1.0) } else { input }
  let n = (q[1] * q[1] + q[2] * q[2] + q[3] * q[3]).sqrt()
  let scale = if n < 1.0e-6 {
    2.0 / q[0].max(1.0e-6)
  } else {
    2.0 * @math.atan2(n, q[0]) / (n + 1.0e-12)
  }
  [q[1] * scale, q[2] * scale, q[3] * scale]
}

///|
pub fn so3_log(m : Array[Double]) -> Array[Double] {
  quat_to_rotvec(mat_to_quat(m))
}

///|
pub fn rot_angle_sq(a : Array[Double], b : Array[Double]) -> Double {
  so3_log(mat_mul(a, transpose(b))).fold(init=0.0, (s, x) => s + x * x)
}

///|
pub fn yaw_mat(m : Array[Double], atlas~ : Bool = false) -> Array[Double] {
  let forward_sq = m[0] * m[0] + m[3] * m[3]
  let vertical = if atlas {
    m[4] * m[4] + m[1] * m[1] > forward_sq
  } else {
    forward_sq < 1.0e-12
  }
  let x = if vertical { m[4] } else { m[0] }
  let y = if vertical { -m[1] } else { m[3] }
  let n = (x * x + y * y).sqrt().max(1.0e-12)
  let (c, s) = (x / n, y / n)
  [c, -s, 0.0, s, c, 0.0, 0.0, 0.0, 1.0]
}

///|
pub fn mat_to_6d(m : Array[Double]) -> Array[Double] {
  [m[0], m[1], m[3], m[4], m[6], m[7]]
}

///|
pub fn quat_slerp(
  a : Array[Double],
  b : Array[Double],
  t : Double,
) -> Array[Double] {
  let dot = Array::makei(4, i => a[i] * b[i]).fold(init=0.0, (s, x) => s + x)
  let b = if dot < 0.0 { vec_scale(b, -1.0) } else { b }
  let theta = @math.acos(dot.abs().min(1.0))
  let s = theta.sin()
  let w0 = if s < 1.0e-6 {
    1.0 - t
  } else {
    ((1.0 - t) * theta).sin() / (s + 1.0e-12)
  }
  let w1 = if s < 1.0e-6 { t } else { (t * theta).sin() / (s + 1.0e-12) }
  normalize(Array::makei(4, i => w0 * a[i] + w1 * b[i]))
}

///|
fn Double::sin(self : Double) -> Double {
  @math.sin(self)
}

///|
fn Double::cos(self : Double) -> Double {
  @math.cos(self)
}

///|
fn Double::exp(self : Double) -> Double {
  @math.exp(self)
}
