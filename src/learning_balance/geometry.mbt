///|
/// Root-relative, row-major 3x3 geometry; all inference is independent of MuJoCo.
pub fn identity() -> Array[Double] {
  [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]
}

///|
pub fn dot(a : Array[Double], b : Array[Double]) -> Double {
  let mut s = 0.0
  for i in 0..<a.length() {
    s += a[i] * b[i]
  }
  s
}

///|
pub fn matvec(a : Array[Double], b : Array[Double]) -> Array[Double] {
  Array::makei(3, fn(i) {
    a[3 * i] * b[0] + a[3 * i + 1] * b[1] + a[3 * i + 2] * b[2]
  })
}

///|
pub fn transpose(a : Array[Double]) -> Array[Double] {
  Array::makei(9, fn(i) { a[i % 3 * 3 + i / 3] })
}

///|
pub fn matmul(a : Array[Double], b : Array[Double]) -> Array[Double] {
  Array::makei(9, fn(i) {
    let r = i / 3
    let c = i % 3
    a[r * 3] * b[c] + a[r * 3 + 1] * b[3 + c] + a[r * 3 + 2] * b[6 + c]
  })
}

///|
pub fn skew(v : Array[Double]) -> Array[Double] {
  [0.0, -v[2], v[1], v[2], 0.0, -v[0], -v[1], v[0], 0.0]
}

///|
pub fn quaternion_matrix(q : Array[Double]) -> Array[Double] {
  let n = dot(q, q).sqrt()
  guard n > 0.0 else { abort("zero quaternion") }
  let w = q[0] / n
  let x = q[1] / n
  let y = q[2] / n
  let z = q[3] / n
  [
    1.0 - 2.0 * (y * y + z * z),
    2.0 * (x * y - z * w),
    2.0 * (x * z + y * w),
    2.0 * (x * y + z * w),
    1.0 - 2.0 * (x * x + z * z),
    2.0 * (y * z - x * w),
    2.0 * (x * z - y * w),
    2.0 * (y * z + x * w),
    1.0 - 2.0 * (x * x + y * y),
  ]
}

///|
pub fn rotation_vector(v : Array[Double]) -> Array[Double] {
  let angle = dot(v, v).sqrt()
  let a = if angle < 1.0e-8 {
    1.0 - angle * angle / 6.0
  } else {
    @math.sin(angle) / angle
  }
  let b = if angle < 1.0e-8 {
    0.5 - angle * angle / 24.0
  } else {
    (1.0 - @math.cos(angle)) / (angle * angle)
  }
  let k = skew(v)
  let kk = matmul(k, k)
  let id = identity()
  Array::makei(9, fn(i) { id[i] + a * k[i] + b * kk[i] })
}

///|
pub(all) struct Hinge {
  observation_index : Int32
  axis : Array[Double]
  anchor : Array[Double]
  reference : Double
} derive(Debug, ToJson, FromJson)

///|
pub(all) struct Body {
  parent : Int32
  position : Array[Double]
  quaternion_wxyz : Array[Double]
  com_position : Array[Double]
  mass : Double
  joints : Array[Hinge]
} derive(Debug, ToJson, FromJson)

///|
pub(all) struct Foot {
  body : Int32
  position : Array[Double]
} derive(Debug, ToJson, FromJson)

///|
pub(all) struct Kinematics {
  nu : Int32
  bodies : Array[Body]
  feet : Array[Foot]
} derive(Debug, ToJson, FromJson)

///|
pub fn Kinematics::body_poses(
  self : Kinematics,
  q : Array[Double],
) -> (Array[Array[Double]], Array[Array[Double]]) {
  let positions = [[0.0, 0.0, 0.0]]
  let rotations = [identity()]
  for i in 1..<self.bodies.length() {
    let body = self.bodies[i]
    guard body.parent >= 0 && body.parent < i else {
      abort("body topology is not parent-first")
    }
    let pr = rotations[body.parent]
    let pp = positions[body.parent]
    let mut r = matmul(pr, quaternion_matrix(body.quaternion_wxyz))
    let offset = matvec(pr, body.position)
    let mut p = Array::makei(3, fn(j) { pp[j] + offset[j] })
    for joint in body.joints {
      let delta = matvec(r, joint.anchor)
      let anchor = Array::makei(3, fn(j) { p[j] + delta[j] })
      r = matmul(
        r,
        rotation_vector(
          joint.axis.map(fn(x) {
            x * (q[joint.observation_index] - joint.reference)
          }),
        ),
      )
      let rotated = matvec(r, joint.anchor)
      p = Array::makei(3, fn(j) { anchor[j] - rotated[j] })
    }
    positions.push(p)
    rotations.push(r)
  }
  (positions, rotations)
}

///|
pub fn Kinematics::geometry(
  self : Kinematics,
  q : Array[Double],
) -> (Array[Double], Array[Array[Double]]) {
  let (p, r) = self.body_poses(q)
  let com = [0.0, 0.0, 0.0]
  let mut mass = 0.0
  for i, body in self.bodies {
    mass += body.mass
    let center = matvec(r[i], body.com_position)
    for j in 0..<3 {
      com[j] += body.mass * (p[i][j] + center[j])
    }
  }
  guard mass > 0.0 && !self.feet.is_empty() else {
    abort("positive mass and support sites required")
  }
  for j in 0..<3 {
    com[j] /= mass
  }
  let feet = self.feet.map(fn(site) {
    let v = matvec(r[site.body], site.position)
    Array::makei(3, fn(j) { p[site.body][j] + v[j] })
  })
  (com, feet)
}

///|
pub fn Kinematics::from_observation(
  self : Kinematics,
  observation : Array[Double],
) -> Array[Double] {
  let (com, feet) = self.geometry(observation)
  let difference = com.copy()
  for foot in feet {
    for j in 0..<3 {
      difference[j] -= foot[j] / feet.length().to_double()
    }
  }
  let gravity = Array::makei(3, fn(j) { observation[2 * self.nu + j] })
  let norm = @math.maximum(dot(gravity, gravity).sqrt(), 1.0e-12)
  let unit = gravity.map(fn(x) { x / norm })
  let projected = dot(difference, unit)
  Array::makei(3, fn(j) { difference[j] - unit[j] * projected })
}
